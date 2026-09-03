// THE ONLY BALLISTIC INTEGRATOR IN THE PROJECT.
//
// There were four: Ball::PredictLanding, the planner's, the pawn's
// PredictBallCrossZ and the AI's PredictBallTimeToHeight. All four answered
// "where does the ball next descend through height Z"; two of them returned the
// first sample PAST the crossing instead of interpolating it, which makes the
// answer jump by a whole step of ball travel every time it is recomputed — a
// 10-20cm sawtooth. That defect was found and fixed in two of the copies months
// apart while the other two kept it, and the pawn's fed the dig platform, whose
// jitter the full-body IK then wrote into the pelvis. Days went into that.
//
// The copies existed for a mechanical reason: Angelscript will not let a global
// function be called from another script module, so anyone who needed this from
// a different file wrote their own. A namespace removes the excuse, and this
// file is neutral ground so the BALL does not have to depend on the AI module
// to use it.
//
// scripts/biomech_report.py fails the run if a fixed-step integrator appears
// outside its allowlist. Two others are exempt, each by measurement rather than
// neglect: Ball::PredictLanding (merging it moved contacts 2.88-3.17 ->
// 2.23-2.36) and AIPlayer::PredictBallTimeToHeight (2.42-2.73), because the
// jump and dive timing is calibrated against that one returning the sample PAST
// the crossing. Making them accurate means retuning what depends on them.
// If you need different behaviour here, add a parameter — do not fork it.

namespace Predict
{
bool BallTimeToHeight(const ABall Ball, float TargetZ, FVector& OutPos, float& OutTime)
{
	FVector P = Ball.Position;
	FVector V = Ball.BallVel;
	const float G = -980.0f;
	const float Dt = 0.02f;
	float T = 0.0f;
	if (P.Z <= TargetZ && V.Z < 0.0f) { OutPos = P; OutTime = 0.0f; return true; }
	while (T < 3.0f)
	{
		V.Z += G * Dt;
		FVector Next = P + V * Dt;
		if (P.Z >= TargetZ && Next.Z <= TargetZ && V.Z < 0.0f)
		{
			// INTERPOLATE the crossing rather than snapping to the sample past
			// it — same reasoning as ABall::PredictLanding. Returning `Next`
			// makes the answer step by one substep of travel every time the
			// remaining step count drops, i.e. a sawtooth at 1/Dt = 50Hz, and
			// this result IS the hitter's move goal (Plan.Contact). A goal that
			// twitches every frame is a goal the body chases every frame.
			float Span = P.Z - Next.Z;
			float Frac = (Span > 0.0001f)
				? Math::Clamp((P.Z - TargetZ) / Span, 0.0f, 1.0f) : 1.0f;
			OutPos = P + (Next - P) * Frac;
			OutTime = T + Dt * Frac;
			return true;
		}
		P = Next;
		T += Dt;
		if (P.Z <= 0.0f) break;
	}
	OutPos = P;
	OutTime = T;
	return false;
}

}   // namespace Predict
