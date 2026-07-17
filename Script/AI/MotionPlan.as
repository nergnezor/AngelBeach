// MotionPlan — the first-principles movement budget.
//
// Every "how do I play this ball" decision is a race between three clocks:
//
//   BALL TIME  τ(z) — when the flight next descends through height z. Exact
//                     ballistics; the ball does not negotiate.
//   BODY TIME       — first-step lag + acceleration-limited run to the spot.
//   HAND TIME       — the ABP's speed-limited FBIK effectors converging the
//                     last arm's-length onto the platform/cup target. They
//                     cannot track from a sprinting body (booth-measured,
//                     see CLAUDE.md), so most of this time must come AFTER
//                     the body has largely arrived.
//
// A contact is PLAYABLE iff τ ≥ body + hand + margin. The plan picks the
// HIGHEST playable contact (earlier contact = more control over the ball),
// runs EXACTLY as fast as the budget demands (a pro with three seconds of
// hang time walks; one with under a second sprints), reports when the reach
// gesture must start, and downgrades to a dive when nothing is playable on
// foot. All rig properties live here as MEASURED constants — update them
// with new measurements, not by feel.

// Physical first-step latency (weight shift + first push), on top of the AI
// reaction tick the caller already pays. Measured: TMe fits at dist/speed+0.12.
const float MB_FirstStepLag = 0.12f;

// FBIK effector convergence speed toward a STATIC target (cm/s). Booth data:
// hands close 60-80cm in the final 0.25-0.35s of a clean contact; attempts
// given less show 50-110cm residuals.
const float MB_HandSpeed = 250.0f;

// Typical hand travel from ready pose to a platform/cup contact target (cm).
const float MB_HandTravel = 90.0f;

// Gesture lead: how long before contact the reach must START. Empirically
// 1.15s produces converged arms and 0.9s does not (miss autopsies) — the
// decomposition is pose-blend ramp (~0.15s) + effector travel (~0.36s) +
// the settle window in which the decelerating body still drags the chest
// anchor around (~0.6s).
const float MB_GestureLead = 1.15f;

// Safety slack demanded on top of body+hand time before calling it playable.
const float MB_Margin = 0.08f;

// How long before contact the body should be PLANTED: the effectors converge
// reliably only from a settled stance (the ~0.6s settle term in the gesture
// lead). Running the speed budget against a thin margin instead of this
// produced "arrive exactly at contact" bodies and the contact rate collapsed
// to 2/39 — efficiency means no WASTED speed, not zero cushion.
const float MB_SettleTime = 0.45f;

// Dive envelope (matches StartDive physics: 1.75x speed burst over 0.42s,
// only worthwhile beyond a lunge and inside the burst's real range).
const float MB_DiveMinDist = 130.0f;
const float MB_DiveMaxDist = 400.0f;
const float MB_DiveMaxTau  = 0.8f;

struct FInterceptPlan
{
	bool bReachable = false;    // some contact is playable on foot
	bool bDive = false;         // nothing on foot — but the dive window is open
	FVector Contact;            // where we meet the ball (ball centre)
	float BallTime = 0.0f;      // τ to Contact
	float BodyTime = 0.0f;      // locomotion time there (incl. first-step lag)
	float HandTime = 0.0f;      // non-overlappable share of hand convergence
	float Slack = 0.0f;         // τ - (BodyTime + HandTime): comfort margin
	float SpeedFraction = 1.0f; // run at exactly this fraction of MoveSpeed
	bool bStartGesture = false; // the reach must begin NOW to converge in time
}

// Ball flight time to the next DOWNWARD crossing of TargetZ. Same 20ms Euler
// the ball itself substeps at; drag (2%/s) is absorbed by MB_Margin. Returns
// false if the flight never descends through TargetZ before landing (OutPos
// then holds the landing point, OutTime the landing time).
bool MB_BallTimeToHeight(ABall Ball, float TargetZ, FVector& OutPos, float& OutTime)
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
			OutPos = Next;
			OutTime = T + Dt;
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

// Acceleration-limited locomotion time over Dist at VMax/Accel, plus the
// physical first-step lag. (Ramp to VMax costs VMax²/2a of distance.)
float MB_BodyTravelTimeRaw(float Dist, float VMax, float Accel)
{
	if (Dist <= 1.0f) return 0.0f;
	float RampDist = (VMax * VMax) / (2.0f * Accel);
	float T = (Dist <= RampDist)
		? Math::Sqrt(2.0f * Dist / Accel)
		: (VMax / Accel) + (Dist - RampDist) / VMax;
	return MB_FirstStepLag + T;
}

// The player's own body-time to cover Dist (mixin: cross-file script
// functions only resolve reliably via the mixin pattern — see PlayerIK).
mixin float BodyTravelTime(AAIPlayer Self, float Dist)
{
	return MB_BodyTravelTimeRaw(Dist, Self.MoveSpeed, Self.GroundAccel);
}

// The planner. Evaluates the preferred contact height first (stroke-specific:
// forehead for a set, waist for a bagger), then the fallback (waist), then
// the dive window. Reads the body from Self; the ball speaks for itself.
mixin FInterceptPlan PlanIntercept(AAIPlayer Self, float PreferredZ, float FallbackZ)
{
	ABall Ball = Self.Ball;
	FVector MyPos = Self.GetActorLocation();
	float MyMoveSpeed = Self.MoveSpeed;
	float MyAccel = Self.GroundAccel;
	FInterceptPlan Plan;
	// The hand share that cannot overlap the run: roughly the second half of
	// the effector travel happens after the body has settled.
	float HandT = (MB_HandTravel / MB_HandSpeed) * 0.5f;

	for (int i = 0; i < 2; i++)
	{
		float Z = (i == 0) ? PreferredZ : FallbackZ;
		if (i == 1 && Math::Abs(FallbackZ - PreferredZ) < 5.0f) break;

		FVector Pos;
		float Tau = 0.0f;
		if (!MB_BallTimeToHeight(Ball, Z, Pos, Tau)) continue;

		float Dist = (MyPos - FVector(Pos.X, Pos.Y, MyPos.Z)).Size2D();
		float BodyT = MB_BodyTravelTimeRaw(Dist, MyMoveSpeed, MyAccel);
		if (Tau < BodyT + HandT + MB_Margin) continue;   // not playable this high

		Plan.bReachable = true;
		Plan.Contact = Pos;
		Plan.BallTime = Tau;
		Plan.BodyTime = BodyT;
		Plan.HandTime = HandT;
		Plan.Slack = Tau - BodyT - HandT;

		// EFFICIENCY: run exactly as fast as the budget demands — where the
		// demand is to be PLANTED a settle-time before contact, not to skid in
		// at the buzzer. Headroom absorbs prediction drift; the floor keeps a
		// purposeful stride. Slack-rich balls are still walked under.
		float Avail = Math::Max(Tau - MB_SettleTime - MB_FirstStepLag, 0.05f);
		float NeedSpeed = Dist / Avail;
		Plan.SpeedFraction = Math::Clamp((NeedSpeed / MyMoveSpeed) * 1.25f, 0.5f, 1.0f);

		// The reach must start MB_GestureLead before contact regardless of
		// where the body is — a late receive is saved by arms extending
		// WHILE closing.
		Plan.bStartGesture = (Tau <= MB_GestureLead);
		return Plan;
	}

	// Nothing playable on foot: is the dive window open? (Same fallback spot
	// the ball gave us — its landing/low crossing.)
	FVector DivePos;
	float DiveTau = 0.0f;
	MB_BallTimeToHeight(Ball, FallbackZ, DivePos, DiveTau);
	float DiveDist = (MyPos - FVector(DivePos.X, DivePos.Y, MyPos.Z)).Size2D();
	float BodyT = MB_BodyTravelTimeRaw(DiveDist, MyMoveSpeed, MyAccel);
	Plan.Contact = DivePos;
	Plan.BallTime = DiveTau;
	Plan.BodyTime = BodyT;
	Plan.bDive = (DiveTau > 0.0f && DiveTau < MB_DiveMaxTau
		&& DiveDist > MB_DiveMinDist && DiveDist < MB_DiveMaxDist
		&& BodyT > DiveTau);
	Plan.bStartGesture = true;   // desperation: arms out no matter what
	return Plan;
}
