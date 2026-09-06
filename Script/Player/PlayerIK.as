// Procedural IK target computation for the volleyball player, factored out of
// AVolleyballPlayer as a mixin so the pawn class stays focused on movement and
// game logic. Call as: Self.UpdateIKTargets(Blend).
//
// Computes WORLD-space effector targets (hands, elbow poles, palm rotations) per
// hit type and writes them into the player's AnimInstance, which feeds them to
// the Full Body IK node in the Anim Blueprint. Anchored to the live skeleton so
// the targets track the body as it moves/jumps; oriented toward the player's aim.
//
// 'Blend' (0..1) is the gesture weight: 0 = relaxed ready pose, 1 = full contact
// pose. Reads Self.CurrentHit / Self.Anim / Self.DesiredAim / the ball (all public
// on AVolleyballPlayer for this mixin). 'Dt' feeds the anti-flicker sink at the end.
// ONE BODY FRAME. Every IK target in this file measures from here, so the
// question "which of my anchors are the solver's own output?" has one answer in
// one place instead of needing a hunt through four hundred lines of waypoint
// maths.
//
// THAT QUESTION IS NOT ACADEMIC. An effector target built from a bone the
// full-body IK writes closes a feedback loop through the solver: it reaches for
// the target, that moves the bone, next frame the target has moved with it.
// No filter can fix that — a rate limit only picks the frequency the loop rings
// at, which is why every smoother added over this file's history measured the
// same or worse. Three separate instances have been found here one at a time
// (ChestMid, the foot echo, the Blend<0.05 hand read), and the comments on
// ReadyShR/L below record an earlier one.
//
// The tainted fields are marked. They are still read from the skeleton because
// replacing them is not free: anchoring ChestMid to the actor was measured on
// 2026-09-03 and cost 24% of ball contacts, since a fixed offset cannot follow
// the torso's lean. Fixing one means modelling what it currently gets for free,
// and paying for the measurement. Do them one at a time, from here.
struct FBodyFrame
{
	// Clean — physics-authoritative or script state. Safe to build targets from.
	FVector Actor;
	FVector Fwd;
	FVector Right;
	FVector Up;
	float Crouch;

	// SOLVER-TAINTED — read from bones the FBIK moves. Each is a live feedback
	// path. Do not add to this list; work it down.
	FVector Head;
	FVector ShR;
	FVector ShL;
	FVector ChestMid;
	FVector FootL;
	FVector FootR;
	FVector HandR;
	FVector HandL;
};

FBodyFrame MakeBodyFrame(AVolleyballPlayer Self)
{
	FBodyFrame B;
	B.Actor = Self.GetActorLocation();
	B.Fwd   = Self.GetActorForwardVector();
	B.Right = Self.GetActorRightVector();
	B.Up    = FVector(0, 0, 1);
	B.Crouch = Self.SmCrouch;

	B.Head = Self.Mesh.GetBoneTransform(n"head").Location;
	B.ShR  = Self.Mesh.GetBoneTransform(n"upperarm_r").Location;
	B.ShL  = Self.Mesh.GetBoneTransform(n"upperarm_l").Location;
	B.ChestMid = (B.ShR + B.ShL) * 0.5f;

	// Last frame's solved foot position — this frame's Two Bone IK target, so a
	// moving pelvis (crouch) doesn't drag the feet through the ground with it.
	B.FootL = Self.Mesh.GetBoneTransform(n"foot_l").Location;
	B.FootR = Self.Mesh.GetBoneTransform(n"foot_r").Location;
	// Guard against a not-yet-posed mesh: before the very first Anim Blueprint
	// evaluation, GetBoneTransform returns the zero vector, which (being far
	// from the actor, wherever it's spawned) is a wildly degenerate Two Bone IK
	// target — the leg stretches toward world origin, and because the target
	// is "read last frame's result", that bad pose is then self-reinforcing
	// instead of self-correcting. Fall back to an approximate ground position
	// under the actor whenever the read foot is implausibly far away.
	B.HandR = Self.Mesh.GetBoneTransform(n"hand_r").Location;
	B.HandL = Self.Mesh.GetBoneTransform(n"hand_l").Location;

	FVector FootFallback = B.Actor - FVector(0, 0, 90.0f);
	if ((B.FootL - B.Actor).SizeSquared() > 200.0f * 200.0f) B.FootL = FootFallback;
	if ((B.FootR - B.Actor).SizeSquared() > 200.0f * 200.0f) B.FootR = FootFallback;
	return B;
}

mixin void UpdateIKTargets(AVolleyballPlayer Self, float Blend, float Dt)
{
	if (Self.Mesh == nullptr) return;

	// Every anchor comes from the one frame — see FBodyFrame above for which of
	// them are the solver's own output and why that matters.
	FBodyFrame Body = MakeBodyFrame(Self);
	FVector Head  = Body.Head;
	FVector ShR   = Body.ShR;
	FVector ShL   = Body.ShL;
	FVector FootL = Body.FootL;
	FVector FootR = Body.FootR;
	FVector Fwd   = Body.Fwd;
	FVector Right = Body.Right;
	FVector Up    = Body.Up;

	// Where the player is sending the ball. Falls back to "up and forward".
	FVector Aim = Self.bHasAim
		? (Self.DesiredAim - Head).GetSafeNormal()
		: (Fwd * 0.4f + Up).GetSafeNormal();
	FVector AimFlat = FVector(Aim.X, Aim.Y, 0).GetSafeNormal();
	if (AimFlat.SizeSquared() < 0.01f) AimFlat = Fwd;

	// Where the BALL is — the hands reach straight toward it, clamped to arm's
	// length from the chest so the IK stays solvable. The player turns to face the
	// ball (FaceBall in the AI), so this naturally ends up in front.
	FVector ChestMid = Body.ChestMid;
	FVector BallContact = ChestMid + Fwd * 35.0f + Up * 5.0f;  // default if no ball
	{
		ABall B = Self.GetWorldBall();
		if (B != nullptr && B.bInPlay)
		{
			FVector ToBall = B.Position - ChestMid;
			float ArmReach = 110.0f;                  // shoulder->hand max (cm)
			if (ToBall.Size() > ArmReach)
				BallContact = ChestMid + ToBall.GetSafeNormal() * ArmReach;
			else
				BallContact = B.Position;             // ball within reach: aim right at it
		}
	}

	// Relaxed ready position: hands hang slightly forward at the sides.
	//
	// Anchored in ACTOR space, not to the shoulder BONES like every other target
	// here. The bones are the solver's OUTPUT: pelvis carries no position
	// stiffness in the IK rig, so it drifts to help the hands reach, which moves
	// the shoulders, which moves these targets, which makes the solver re-solve —
	// a closed loop with nothing damping it. Measured at the bones, the hips were
	// reversing direction 10.5 times a second while every script-side input read
	// perfectly clean. The gesture targets genuinely need live bones (the hand has
	// to arrive where the shoulder actually is); a pose whose whole job is "hands
	// hang at the sides" does not, so it is the one that can leave the loop.
	float ReadyCrouch = Math::Max(Self.ExtraCrouch, Self.HeldCrouch);
	FVector ActorMid = Self.GetActorLocation();
	float ShoulderUp = 55.0f - ReadyCrouch * 30.0f;   // hips sink, shoulders follow
	FVector ReadyShR = ActorMid + Up * ShoulderUp + Right * 18.0f;
	FVector ReadyShL = ActorMid + Up * ShoulderUp - Right * 18.0f;
	FVector ReadyR = ReadyShR + Fwd * 18.0f - Up * 35.0f;
	FVector ReadyL = ReadyShL + Fwd * 18.0f - Up * 35.0f;

	FVector ContactR;
	FVector ContactL;
	FRotator PalmR = FRotator::ZeroRotator;
	FRotator PalmL = FRotator::ZeroRotator;
	FVector PoleR;
	FVector PoleL;
	float Crouch = 0.0f;
	// How far past the anti-flicker sink's base speed limit this frame's pose
	// may legitimately move (deliberate swings are FAST — see the sink).
	float SinkBoost = 1.0f;
	// Hand acceleration ceiling (cm/s^2), before SinkBoost opens it. Sized from
	// the reversal it has to civilise: at 120Hz this bleeds a full-speed hand to
	// a stop in ~0.1s rather than in one frame, and a swing's boost roughly
	// halves that again.
	const float HandSinkAccel = 18000.0f;

	// 0 -> 1 over the contact swing (TriggerHit envelope): lets poses swing
	// THROUGH the ball along the aim at contact instead of freezing on it.
	float Swing = Self.SwingProgress();

	// --- THE PREPARATION CLOCK ----------------------------------------------
	// 0 when the gesture began, 1 at the contact it was started for. The pawn
	// carries the time-to-contact the planner handed over (Self.ReachTau); this
	// turns it into the monotone progress the poses are choreographed against
	// (see GestureClock — a wind-up never un-winds).
	//
	// Every stroke below used to be posed as a function of Blend alone, which is
	// the 0.2s ramp that says "a gesture exists". So the whole gesture lead — a
	// second and a bit that the planner deliberately buys, and that the AI
	// spends walking to the spot and planting — was animated as: snap into the
	// final contact shape, then hold it, motionless, until the ball turns up.
	// A player with no wind-up.
	const float PrepWindow = 1.15f;   // = MB_GestureLead, the lead the planner buys
	const float PrepSettle = 0.40f;   // parked poses are DONE this long before contact
	{
		float Raw;
		if (Self.ReachTau < 90.0f)
			Raw = Math::Clamp((PrepWindow - Self.ReachTau) / PrepWindow, 0.0f, 1.0f);
		else
			Raw = Blend;   // no plan behind this reach (AutoReach, dive rescue)
		if (Swing > 0.0f) Raw = 1.0f;              // contact fired: the wind-up is over
		if (Raw > Self.GestureClock) Self.GestureClock = Raw;
	}
	// The poses that PARK at the meet point (bump, set) want to arrive EARLY and
	// then be still — "set your platform and let the ball come to you", and the
	// hard-won rule that a static target is the one thing the speed-limited FBIK
	// reliably converges on. So their preparation runs out at PrepSettle, not at
	// contact. The whip strokes use GestureClock raw: a bow has to be drawn at
	// the moment the hand meets the ball, not a third of a second before it.
	float Prep = MinJerk(Math::Clamp(
		Self.GestureClock * PrepWindow / (PrepWindow - PrepSettle), 0.0f, 1.0f));

	if (Self.CurrentHit == EHitType::Hit_Bump)
	{
		// Bagger/dig: arms STRAIGHT, hands JOINED, contact on the FOREARMS. The
		// hand targets are pushed to near-full extension along the shoulder->ball
		// line — even past the ball if it's close — because a bent-elbow "hands on
		// the ball" pose reads as poking, not a platform. With the hands beyond the
		// ball line, the forearm segment is what meets the ball (which is also
		// where GetArmContact tests lowerarm bones).
		//
		// While the ball is still descending toward us, PARK the platform at the
		// PREDICTED meet point (where the ball crosses waist height) instead of
		// tracking the live ball: a static target is the one thing the ABP's
		// speed-limited FBIK reliably converges on. "Set your platform early and
		// let the ball come to you" — literally. Once the ball is at/below meet
		// height the live position takes over (they coincide by then).
		// ONE contact point, handed over with the reach request (see Reach) —
		// the same one the feet are walking to. There is no second prediction
		// here any more, and no switch between "parked meet point" and "live
		// ball": the point IS where the ball will be, so the two coincide by
		// the time it arrives.
		FVector PlatformBall = BallContact;
		if (Self.bHasReachContact)
		{
			FVector ToMeet = Self.SmReachContact - ChestMid;
			// CLAMP TO ARM'S REACH, not to 110cm. The arm spans ~72 from ChestMid
			// (hands joined on the centreline), so a 110 goal is unreachable and
			// the full-body IK answers that by dragging the ROOT the difference.
			// Measured, feet still with the dig intent set: the pelvis sat 38.8cm
			// from the capsule at the median and 121.6 at p90 — the body walking
			// a metre away from the player it belongs to, pinned at exactly this
			// clamp. Off the gesture it sits 0.9cm out.
			PlatformBall = (ToMeet.Size() > 72.0f)
				? ChestMid + ToMeet.GetSafeNormal() * 72.0f
				: Self.SmReachContact;
		}
		FVector Platform = PlatformBall - Up * 12.0f;

		// A SHORT VECTOR HAS NO RELIABLE DIRECTION, and PlatEnd is placed by
		// taking the bearing from the chest to the meet point and walking Ext
		// (72cm+) along it — so the hand's position is set by that direction
		// ALONE. Normalise a 5cm vector and a millimetre of prediction wobble
		// becomes a centimetre of hand travel. Measured (PLATAMP below), platform
		// step against meet-point step, bucketed by chest-to-meet range:
		//
		//   0-15cm    3.59x       (n=159)
		//   15-30cm   1.11x
		//   30cm+     ~1.0x or below
		//
		// 0-15cm is not a rare corner — it is where a dig is actually taken, so
		// the amplifier is loudest exactly at contact. The guard below only
		// catches an exactly-degenerate vector (under 1mm) and never fires, while
		// the noisy band starts two orders of magnitude higher.
		//
		// So hold the last well-conditioned bearing while inside the noisy band —
		// the same cure RequestBallFacing uses for the body — and let it die with
		// the gesture (see the Blend passthrough), because carried across strokes
		// it would point the next bagger wherever the previous ball happened to
		// be.
		//
		// It cuts the bagger's reversals 106 -> 63 and lowers wasted yaw per
		// standing second (47-54 -> 23-40) with no gated metric worse. It only
		// PARTLY addresses what it was aimed at, though: the amplification itself
		// moves 3.59 -> 3.37, because a gesture that STARTS with the ball already
		// inside the band has no good bearing to hold and falls through to the
		// raw path. The rest of that is still open.
		const float PlatDirMinRange = 25.0f;
		FVector RawPlatDir = Platform - ChestMid;
		FVector PlatDir;
		if (RawPlatDir.Size() >= PlatDirMinRange)
		{
			PlatDir = RawPlatDir.GetSafeNormal();
			Self.SmPlatDir = PlatDir;
		}
		else if (Self.SmPlatDir.SizeSquared() > 0.01f)
			PlatDir = Self.SmPlatDir;
		else
			PlatDir = RawPlatDir.GetSafeNormal();
		if (PlatDir.SizeSquared() < 0.01f) PlatDir = Fwd - Up;
		// 72cm, not 96: NEVER ASK THE SOLVER FOR SOMETHING IT CANNOT REACH.
		// The hands join on the centreline, so the span available from ChestMid
		// (the midpoint between the shoulders) is about one arm, ~70cm. Asking
		// for 96 put the goal permanently out of range, and a full-body IK
		// solver answers an unreachable goal by moving the root — which is the
		// pre-pull that made the hips travel with the hand target.
		//
		// This is the sideways half of the shake. Capping the pre-pull's Z alone
		// (IK_Mannequin, previous commit) left the solver the other two axes to
		// close the same impossible gap in, and it used them: reported as "nu ser
		// det ut som spelaren skakar i sidled innan mottag", and measured as the
		// hip's Y reversals rising 4.27 -> 6.86 per second while Z fell.
		//
		// Measured with the feet still and the dig intent set, hip reversals
		// larger than 3cm per second, against contacts per rally:
		//
		//   Ext 96, pre-pull on     X 23.49  Y  4.27  Z 12.81   3.31
		//   Ext 96, pre-pull Z off  X  5.21  Y  6.86  Z  1.73   2.86
		//   Ext 72, pre-pull Z off  X  4.05  Y  4.02  Z  1.52   3.24
		//   Ext 72, pre-pull on     X  9.91  Y 12.04  Z  4.49   2.60
		//
		// The last row is why both changes stay: a reachable goal is not enough
		// on its own, because the pre-pull drags the root toward the goal whether
		// or not the arm could have got there by itself.
		// THE HAND GOES WHERE THE BALL WILL BE, IT DOES NOT ORBIT THE CHEST.
		//
		// This used to take the BEARING to the meet point and walk 72cm along it,
		// so the hand sat on a sphere around the chest and its position was set by
		// that direction alone. Measured (PLATAMP): a step of the meet point
		// became 2.45x that at the hand inside 15cm, 2.28 out to 30 — the ranges a
		// dig is actually taken at. Every centimetre of re-prediction was
		// multiplied for the whole last half second of the stroke, which is what
		// "baggern ser för flängig ut" is.
		//
		// Tracking the POSITION instead makes that gain 1: the hand moves exactly
		// as much as the point it is going to. The elbows no longer lock out on a
		// ball that comes in close, which is what a real dig looks like anyway.
		// Freezing the platform after the preparation was tried first and is a
		// much worse idea: contacts per rally 8.31 -> 3.06 with 27% of rallies
		// dying on one touch, because the meet point moves for real reasons too.
		float Ext = Math::Max((Platform - ChestMid).Size(), 72.0f);  // lock the elbows out
		// THE PLATFORM IS BUILT, NOT CONJURED. It starts as the loaded ready
		// shape every defender waits in — hands joined low and in front, elbows
		// still bent — and travels out to the meet point, arriving locked out and
		// planted PrepSettle before the ball. That is the same pose it used to
		// teleport into; the only thing that changed is that the second of lead
		// time now contains the movement into it.
		//
		// THE READY END IS ANCHORED IN ACTOR SPACE, not on ChestMid, for exactly
		// the reason the Ready hands above are: the chest is the SOLVER'S OUTPUT.
		// A target defined purely relative to it is a closed loop with nothing
		// damping it, and this one is worse than the ready pose because the whole
		// preparation would ride it. Measured with the first (chest-anchored)
		// version of this build: pelvis reversals 1-7 per run -> 9-14. The final
		// platform still hangs off the chest — it has the meet point, a world
		// anchor, holding the other end.
		FVector ToPlat = Platform - ChestMid;
		FVector PlatFinal = (ToPlat.Size() > 72.0f)
			? ChestMid + PlatDir * Ext
			: ChestMid + ToPlat;
		FVector PlatReady = ActorMid + Up * (ShoulderUp - 30.0f) + Fwd * 30.0f;
		FVector PlatEnd = PlatReady + (PlatFinal - PlatReady) * Prep;
		// At contact the platform SWINGS THROUGH the ball, lifting along the aim —
		// a bagger is a controlled swing from the shoulders, not a held tray.
		//
		// CUSHION FIRST, THEN DRIVE — the same shape the set below already uses,
		// and for the same reason. This used to be a bare EaseOut(Swing), which
		// has its steepest slope at Swing=0: the platform spent the approach
		// travelling DOWN to meet the ball and then, in the frame contact fired,
		// started travelling UP the aim at full rate. That is a velocity
		// reversal with no deceleration between the halves, and it was the
		// bagger's share of the jerk — 365 of the first 480 reversals logged
		// were this gesture, and the survivors cluster at swing 0.10-0.21 with a
		// mean turn of 123 degrees.
		//
		// A real platform absorbs the ball before it lifts it. MinJerk on both
		// segments puts zero slope at contact AND at the seam between them, so
		// there is no corner in velocity anywhere in the stroke: the platform
		// gives a few centimetres into the ball, pauses, then drives through.
		FVector SwingThrough = AimFlat * 26.0f + Up * 18.0f;
		float SwingT;
		if (Swing < 0.22f)
			SwingT = -0.18f * MinJerk(Swing / 0.22f);                      // absorb
		else
			SwingT = -0.18f + 1.18f * MinJerk((Swing - 0.22f) / 0.78f);    // drive through
		PlatEnd += SwingThrough * SwingT;

		// DIAG: how much does a wobble in the meet point move the hand? PlatEnd
		// sits on a sphere of radius Ext around ChestMid and its position is set
		// purely by the DIRECTION to the meet point, so the answer should be
		// Ext/range — i.e. amplification grows as the ball comes closer in.
		//
		// BOTH STEPS ARE MEASURED IN THE CHEST'S FRAME, and that is the whole
		// difference between this probe meaning something and not. Taken in world
		// space it also counts the BODY WALKING: a running player carries PlatEnd
		// with them while the meet point stands still, which is a ratio of
		// infinity and has nothing to do with a bearing. It read as amplification
		// 11.2 at ranges past 30cm — where the model says the answer cannot
		// exceed Ext/range ~ 2.4 — purely because the gesture now starts a second
		// before contact, with the hitter still closing.
		if (Self.MonPlatLogs < 60 && Self.bHasReachContact)
		{
			FVector RelReach = Self.ReachContact - ChestMid;
			FVector RelPlat = PlatEnd - ChestMid;
			float Range = RelReach.Size();
			// SPEND THE SAMPLE BUDGET WHERE THE MODEL SAYS THE DANGER IS. The
			// cap used to be filled by the long-range frames at the start of a
			// gesture, which is exactly where amplification cannot happen
			// (Ext/range < 1.2 out there), leaving the near field with almost no
			// parked samples to judge from.
			if (Self.bMonPlatInit && Range < 45.0f)
			{
				float RStep = (RelReach - Self.MonPrevReachC).Size();
				float PStep = (RelPlat - Self.MonPrevPlatEnd).Size();
				if (RStep > 0.05f)
				{
					Self.MonPlatLogs++;
					// PREP MUST BE ON THE LINE. The ratio below only means
					// "how much does meet-point noise move the hand" while the
					// platform is PARKED; during the build the hand is travelling
					// out to the meet point on purpose, and counting that as
					// amplification reads as a threefold regression at every
					// range (measured: 30cm+ went 1.0 -> 3.44 the day the build
					// landed, entirely from this).
					Log("PLATAMP reachStep=" + int(RStep * 100) + " platStep=" + int(PStep * 100)
						+ " range=" + int(Range) + " ext=" + int(Ext)
						+ " prep=" + int(Prep * 100)
						+ " swing=" + int(Swing * 100));
				}
			}
			Self.MonPrevReachC = RelReach;
			Self.MonPrevPlatEnd = RelPlat;
			Self.bMonPlatInit = true;
		}

		ContactR = PlatEnd - Right * 5.0f;
		ContactL = PlatEnd + Right * 5.0f;
		// Elbow hints sit ON the shoulder->hand line, nudged down/in, so the IK
		// keeps the arms straight instead of chicken-winging them outward — and
		// they travel with the platform, or they would point at the meet point
		// while the hands are still gathered low in front of the hips.
		FVector ReadyPoleR = ReadyShR + Fwd * 16.0f - Up * 30.0f - Right * 4.0f;
		FVector ReadyPoleL = ReadyShL + Fwd * 16.0f - Up * 30.0f + Right * 4.0f;
		PoleR = ShR + PlatDir * 45.0f - Up * 22.0f - Right * 6.0f;
		PoleL = ShL + PlatDir * 45.0f - Up * 22.0f + Right * 6.0f;
		PoleR = ReadyPoleR + (PoleR - ReadyPoleR) * Prep;
		PoleL = ReadyPoleL + (PoleL - ReadyPoleL) * Prep;
		// Forearm platform faces up toward the aim arc.
		PalmR = (AimFlat * 0.5f + Up).GetSafeNormal().Rotation();
		PalmL = PalmR;
		// THE LEGS SET THE PLATFORM HEIGHT: the lower the ball, the deeper the
		// knees, while the arms keep their stable slope. Range 0.5-0.7:
		// empirically (booth4 vs booth6/7) the ABP crouch blend keeps a
		// functional stance with the hands reaching the ball up to ~0.7; beyond
		// that it becomes a one-knee kneel whose dropped chest puts the platform
		// targets outside the reach envelope and the solver gives up (hands end
		// up at the thighs).
		// The knee depth keys on the BALL's height (pose-independent), never on
		// the chest: chest-derived depth fed back through the ABP (crouch
		// lowers the chest → recomputed depth → new crouch) and the legs
		// oscillated at up to 29 direction flips per half-second window — the
		// exact up-and-down shake the jitter monitor caught (crouchFlips).
		// ...and "the ball" must be the UNCLAMPED meet/ball height: PlatformBall
		// is clamped onto a 110cm sphere around the CHEST when the meet point is
		// out of reach (mid-run), which sneaks the chest back into the loop —
		// crouch lowers chest, lowers PlatformBall.Z, deepens BallLow, deepens
		// crouch. That was the residual mid-run crouchFlips source (stats22-24).
		float KneeKeyZ = PlatformBall.Z;
		if (Self.bHasReachContact)
		{
			KneeKeyZ = Self.SmReachContact.Z;
		}
		else
		{
			ABall KB = Self.GetWorldBall();
			if (KB != nullptr && KB.bInPlay) KneeKeyZ = KB.Position.Z;
		}
		float FeetZ = Self.GetActorLocation().Z - Self.PlayerHeight;
		float ContactAboveFeet = KneeKeyZ - FeetZ;
		float BallLow = Math::Clamp((110.0f - ContactAboveFeet) / 80.0f, 0.0f, 1.0f);
		Crouch = 0.5f + 0.2f * BallLow;
		// ...AND THE LEGS DRIVE THROUGH THE BALL. The knees held their depth
		// through the whole stroke, so the platform lifted along the aim off a
		// body that was doing nothing — arms moving alone is what reads as
		// flapping. They extend on the same seam the platform drives from
		// (Swing 0.22, after the cushion), so legs, hips and platform all leave
		// together in one direction. The set has done this since it was written;
		// the dig never did.
		Crouch *= 1.0f - MinJerk(Math::Clamp((Swing - 0.22f) / 0.6f, 0.0f, 1.0f));
	}
	else if (Self.CurrentHit == EHitType::Hit_Set)
	{
		// Fingerpass/set from first principles — the overhead "window" set:
		//  - hands form a triangle window ABOVE THE FOREHEAD, elbows OUT and
		//    forward, palms up toward the ball (the finger pads take it);
		//  - at contact the wrists/elbows GIVE a touch to load (the cushion),
		//  - then the whole body EXTENDS through the ball toward the aim — legs,
		//    elbows and wrists straightening together. A set with no cushion and
		//    no leg drive reads as a stiff tap.
		// Same park-at-the-meet-point trick as the bump: the window waits where
		// the ball will cross brow height instead of chasing it down.
		// Same one contact point as the bump above. The set's own height came
		// from a separate copy of the prediction (PredictedMeetHigh); it now
		// comes from ContactHeightFor(Hit_Set), which is where the planner
		// already put the feet.
		FVector CupBall = BallContact;
		if (Self.bHasReachContact)
		{
			FVector ToMeet = Self.SmReachContact - ChestMid;
			CupBall = (ToMeet.Size() > 72.0f)
				? ChestMid + ToMeet.GetSafeNormal() * 72.0f
				: Self.SmReachContact;
		}
		FVector Cup = CupBall - Up * 6.0f;                   // finger window just under the ball
		// PREPARATION: the window is not born above the brow. The hands gather in
		// front of the chest and RISE into it, finishing before the ball arrives
		// (Prep runs out at PrepSettle). Same reason as the bump's build — and the
		// gathered end is in ACTOR space for the same reason too (see there).
		FVector ReadyCup = ActorMid + Up * (ShoulderUp - 4.0f) + Fwd * 22.0f;
		Cup = ReadyCup + (Cup - ReadyCup) * Prep;
		FVector Push = (AimFlat * 0.6f + Up * 0.8f).GetSafeNormal();

		// Offset along the push axis: CUSHION (give) then DRIVE through. Swing is
		// 0 until the real contact fires TriggerHit, so pre-contact the window
		// just holds under the ball; the give+extend is the follow-through. MinJerk
		// on the approach: the window SETTLES under the ball, not snaps to it.
		// MinJerk (not linear) on both the give and the drive too: a linear give
		// meeting a linear drive at the Swing=0.2 seam has matching POSITION but a
		// hard corner in VELOCITY there (give ends at -108cm/s, drive starts at
		// +81cm/s) — an instant direction reversal that read as a flail. MinJerk
		// has zero slope at both ends of each segment, so the hands actually pause
		// at the bottom of the cushion before driving through, like a real catch.
		float Along;
		if (Swing <= 0.0f)
			Along = 6.0f * MinJerk(Blend);                              // window forming, waiting
		else if (Swing < 0.2f)
			Along = 6.0f - 14.0f * MinJerk(Swing / 0.2f);               // CUSHION: give down to -8 (load)
		else
			Along = -8.0f + 42.0f * MinJerk((Swing - 0.2f) / 0.8f);     // EXTEND: drive up & through
		FVector Extend = Push * Along;

		// Hands ~20cm apart, UNCROSSED (right hand right, left hand left). The old
		// pose crossed them — inherited from the bump's symmetric ±Right split,
		// where the joined platform makes the side irrelevant, but here it
		// X-crossed the forearms over the head.
		ContactR = Cup + Right * 10.0f + Extend;
		ContactL = Cup - Right * 10.0f + Extend;
		// Elbows OUT to the sides and forward — the open triangle window. (The old
		// poles pulled the elbows INWARD, cramping the shape into a pancake.)
		// They OPEN as the window rises: tucked at the ribs while gathering, out
		// and forward once the triangle is up.
		FVector ReadyPoleR = ReadyShR + Fwd * 8.0f + Right * 7.0f - Up * 20.0f;
		FVector ReadyPoleL = ReadyShL + Fwd * 8.0f - Right * 7.0f - Up * 20.0f;
		PoleR = ShR + Fwd * 30.0f + Right * 18.0f + Up * 4.0f;
		PoleL = ShL + Fwd * 30.0f - Right * 18.0f + Up * 4.0f;
		PoleR = ReadyPoleR + (PoleR - ReadyPoleR) * Prep;
		PoleL = ReadyPoleL + (PoleL - ReadyPoleL) * Prep;
		PalmR = (AimFlat * 0.5f + Up).GetSafeNormal().Rotation();
		PalmL = PalmR;
		// Legs load through the cushion and EXTEND through the drive — a set's
		// power is a full-body push, not just the arms. Single-direction in Swing
		// so it can't oscillate (the crouch-jitter class we just closed).
		Crouch = 0.22f - 0.22f * Math::Clamp((Swing - 0.2f) / 0.5f, 0.0f, 1.0f);
	}
	else if (Self.CurrentHit == EHitType::Hit_Spike)
	{
		// Spike — a REAL overhand arm swing from first principles, in four phases.
		// The hitting (right) arm draws a bow and whips over the top; the left arm
		// is the timing / counter-rotation arm.
		//
		//   1 BACKSWING  the arm is swung back at ~shoulder height as the body
		//                rises on the approach (both arms have lifted together).
		//   2 COCKED     the bow fully drawn: elbow HIGH, hand dropped back ABOVE
		//                and BEHIND the head — the loaded position a real hitter
		//                snaps from. (The old pose cocked "outside the cheek" from
		//                a hand-low-behind-the-hip backswing — an underhand throw
		//                shape, not an overhand spike.)
		//   3 STRIKE     the elbow leads, the forearm whips over the top, the hand
		//                meets the ball at full extension above & in front.
		//   4 FOLLOW     AFTER contact the hand snaps DOWN and ACROSS the body to
		//                the opposite hip. Without a follow-through the arm freezes
		//                at extension and reads as a push; the finish is what makes
		//                it a whip.
		//
		// Phases 1->3 are timed to the BALL DESCENDING toward the strike point
		// (SwingPhase); phase 4 is driven by the post-contact swing envelope
		// (Swing — exactly 0 until the real hit fires TriggerHit), so the finish
		// plays only once we've actually connected. A whiffed swing simply retracts
		// along the windup instead.
		FVector BackSw = ShR - Fwd * 18.0f - Up * 6.0f + Right * 16.0f;   // swung back, shoulder height
		FVector Cocked = Head - Fwd * 16.0f + Right * 6.0f + Up * 24.0f;  // drawn bow: above & behind the head

		// Reach for the REAL ball height, not the 110cm-clamped contact point:
		// the FBIK saturates at full extension so over-asking costs nothing,
		// while under-asking left the strike hand ~40cm below the ball at the
		// jump apex (the stats2 whiffs).
		float BallZRaw = BallContact.Z;
		{
			ABall RB = Self.GetWorldBall();
			if (RB != nullptr && RB.bInPlay) BallZRaw = RB.Position.Z;
		}
		float StrikeUp = Math::Clamp(BallZRaw - ShR.Z, 35.0f, 125.0f);
		FVector Strike = ShR + Up * StrikeUp + Fwd * 24.0f + Right * 6.0f;  // above & front of R shoulder
		FVector Finish = ShR - Up * 42.0f + Fwd * 6.0f - Right * 32.0f;     // snap down & across to far hip

		// TIME is the honest clock for a wind-up: the bow has to be fully drawn
		// at the moment the hand meets the ball. The ball-drop remap below reads
		// like it does that, but it normalises over 260cm and a SET only peaks
		// about a metre above the strike point — so every swing started at
		// SwingPhase 0.6, already past the cocked phase, and the attacker's arm
		// went straight to the strike with no backswing at all. That is the
		// spike's share of "inga förberedande rörelser". The drop remap stays as
		// the fallback for reaches nobody planned (AutoReach, whiff rescue).
		// ...and it finishes SpikeLead BEFORE contact, not at it. The FBIK
		// effectors converge at a limited speed, so a hand whose target reaches
		// the strike point exactly at tau=0 arrives after the ball has gone —
		// the same lesson the serve toss cost (choreograph unhurried, give the
		// gesture lead time). Timing the bow to land on tau=0 measured 10-15
		// attacks against 14-18 for the old drop clock.
		const float SpikeLead = 0.18f;
		float SwingPhase = Blend;
		if (Self.ReachTau < 90.0f)
		{
			SwingPhase = Math::Clamp(
				Self.GestureClock * PrepWindow / (PrepWindow - SpikeLead), 0.0f, 1.0f);
		}
		else
		{
			ABall SB = Self.GetWorldBall();
			if (SB != nullptr && SB.bInPlay)
			{
				// 0 when the ball is >=260cm above the strike height, 1 at contact.
				float Drop = SB.Position.Z - Strike.Z;
				SwingPhase = Math::Clamp(1.0f - Drop / 260.0f, 0.0f, 1.0f) * Blend;
			}
		}

		// --- Right (hitting) arm --------------------------------------------
		// Each phase gets the time profile (and shoulder-centred ARC, not a
		// straight line) that matches what it physically is: the backswing
		// SETTLES into the cocked position (MinJerk), the whip must hit the
		// ball at PEAK speed rather than decelerate into it (EaseIn), the
		// follow-through starts at strike speed and bleeds off (EaseOut).
		if (Swing > 0.001f)
		{
			// Contact has happened: whip through from the strike to the finish.
			ContactR = ArcAround(ShR, Strike, Finish, EaseOut(Swing));
			PoleR = ContactR + Up * 12.0f - Fwd * 4.0f + Right * 8.0f;      // elbow drops & leads the snap
		}
		else if (SwingPhase < 0.4f)
		{
			// Backswing -> cocked: draw the bow as the body rises.
			ContactR = ArcAround(ShR, BackSw, Cocked, MinJerk(SwingPhase / 0.4f));
			PoleR = ContactR + Up * 22.0f - Fwd * 26.0f + Right * 12.0f;    // elbow high & back
		}
		else
		{
			// Cocked -> strike: the forward whip as the ball drops in. The elbow
			// travels forward and down, leading the hand over the top.
			float T = EaseIn((SwingPhase - 0.4f) / 0.6f);
			ContactR = ArcAround(ShR, Cocked, Strike, T);
			PoleR = ContactR + Up * (22.0f - 8.0f * T) - Fwd * (26.0f - 40.0f * T) + Right * 10.0f;
		}
		// The whip is a deliberate ballistic motion — open the anti-flicker
		// sink for it (build-up AND the post-contact snap), so the strike
		// isn't capped at the same speed as ordinary repositioning.
		SinkBoost = 1.0f + 1.6f * Math::Max(SwingPhase, Swing);
		// Palm rolls from facing up/back (cocked) to down along the aim (strike +
		// follow-through, over the top of the ball).
		float PalmT = Math::Clamp(Math::Max((SwingPhase - 0.4f) / 0.6f, Swing), 0.0f, 1.0f);
		PalmR = (AimFlat * 0.5f + Up * (1.0f - PalmT) - Up * 0.6f * PalmT).GetSafeNormal().Rotation();

		// --- Left (timing / counter-rotation) arm ---------------------------
		// Points at the ball through the windup, then PULLS DOWN to the ribs as
		// the right whips over — the counter-rotation every real hitter uses for
		// power. A left arm that keeps pointing through contact is the tell of a
		// video-game spike. The pull tracks the strike (SwingPhase) and stays
		// tucked through the follow-through (Swing).
		FVector ToBallL = (BallContact - ShL);
		float ReachL = 95.0f;
		if (ToBallL.Size() > ReachL) ToBallL = ToBallL.GetSafeNormal() * ReachL;
		FVector PointL = ShL + ToBallL;
		FVector TuckL  = ShL - Up * 28.0f + Fwd * 12.0f;   // elbow-down tuck at the ribs
		float LeftPull = Math::Clamp(Math::Max((SwingPhase - 0.5f) / 0.4f, Swing), 0.0f, 1.0f);
		ContactL = PointL + (TuckL - PointL) * LeftPull;
		if (LeftPull < 0.5f)
		{
			PoleL = ShL + ToBallL * 0.4f - Up * 15.0f;     // elbow softly under the aim line
			PalmL = ToBallL.GetSafeNormal().Rotation();
		}
		else
		{
			PoleL = ShL - Up * 20.0f - Fwd * 10.0f;        // elbow folds down/back
			PalmL = (-Up).Rotation();
		}
		Crouch = 0.0f;
	}
	else if (Self.CurrentHit == EHitType::Hit_Block)
	{
		// Block: both hands reach UP and toward the ball, as high/close as the arms
		// allow, angled so the palms face DOWN into the middle of the opponent's
		// court (DesiredAim) — that's where we want to deflect a spike. Hands press
		// together (penetrate the net) rather than spread wide.
		FVector ToBall = BallContact - ChestMid;
		float ArmUp = 95.0f;                         // near-full vertical reach
		FVector Up95 = ToBall;
		if (Up95.Size() > ArmUp) Up95 = Up95.GetSafeNormal() * ArmUp;
		FVector BlockMid = ChestMid + Up95;          // both hands converge here, high
		ContactR = BlockMid + Right * 9.0f;          // hands close together
		ContactL = BlockMid - Right * 9.0f;
		// Elbows high and slightly forward so the arms form a firm wall.
		PoleR = ContactR + Fwd * 25.0f - Up * 5.0f;
		PoleL = ContactL + Fwd * 25.0f - Up * 5.0f;
		// Palms face down-and-toward the aim (middle of opponent court) to push the
		// blocked ball back down into their court.
		FVector PalmDir = (AimFlat * 0.6f - Up).GetSafeNormal();
		PalmR = PalmDir.Rotation();
		PalmL = PalmDir.Rotation();
		Crouch = 0.0f;
	}
	else if (Self.CurrentHit == EHitType::Hit_Serve)
	{
		// Serve, choreographed by ServePhase (0..1, driven by the AI's serve
		// sequence — NOT by the ball):
		//  - LEFT arm carries the ball up from the chest to a toss apex in front
		//    of the RIGHT shoulder (textbook toss placement), then tucks away.
		//  - RIGHT arm draws back behind the ear like a bow, whips overhead to
		//    strike at the apex, and follows through down the aim line.
		float P = Math::Clamp(Self.ServePhase, 0.0f, 1.0f);
		FVector TossApex = ChestMid + Fwd * 24.0f + Up * 62.0f + Right * 10.0f;

		FVector TossStart = ChestMid + Fwd * 30.0f - Up * 6.0f + Right * 6.0f;
		FVector TossHand  = TossApex - Up * 16.0f;   // ball rides 16cm above this hand
		FVector TuckL     = ShL - Up * 26.0f + Fwd * 10.0f;
		if (P < 0.6f)
		{
			float T = P / 0.6f;
			ContactL = TossStart + (TossHand - TossStart) * MinJerk(T);  // bell-velocity lift
			PoleL = ShL + Fwd * 35.0f - Up * 4.0f;
			PalmL = Up.Rotation();                    // palm up, carrying the ball
		}
		else
		{
			float T = (P - 0.6f) / 0.4f;
			ContactL = TossHand + (TuckL - TossHand) * MinJerk(T);
			PoleL = ShL - Up * 18.0f - Fwd * 8.0f;
			PalmL = (-Up).Rotation();
		}
		// The script-computed target, not the solved bone — see the field's
		// comment in VolleyballPlayer.as for why RunServeSequence reads this.
		Self.ServeTossTarget = ContactL;

		FVector RestR   = ShR + Fwd * 15.0f - Up * 22.0f;
		FVector DrawR   = Head + Right * 24.0f - Fwd * 14.0f + Up * 4.0f;  // drawn behind the ear
		FVector StrikeR = TossApex + Up * 6.0f;                            // meet the ball at the apex
		FVector FollowR = ShR + Fwd * 55.0f + Up * 8.0f;
		// Segment boundaries match the SERVE PHYSICS: the ball launches at phase
		// 0.78 (ServeStrikePhase), so the hand must be AT StrikeR exactly then —
		// the old 0.85 breakpoint had the ball leaving mid-whip.
		if (P < 0.55f)
		{
			// Draw: a MinJerk reach that SETTLES into the cocked position.
			float T = P / 0.55f;
			ContactR = ArcAround(ShR, RestR, DrawR, MinJerk(T));
			PoleR = ContactR + Up * 20.0f - Fwd * 25.0f + Right * 12.0f;
		}
		else if (P < 0.78f)
		{
			// Whip: EaseIn on an arc — peak hand speed AT the strike (phase
			// 0.78, where the ball physically launches). Open the sink for it.
			float T = (P - 0.55f) / 0.23f;
			ContactR = ArcAround(ShR, DrawR, StrikeR, EaseIn(T));
			PoleR = ContactR + Up * 18.0f - Fwd * 20.0f + Right * 10.0f;
			SinkBoost = 1.0f + 1.4f * T;
		}
		else
		{
			// Follow-through: starts at strike speed, bleeds off along the arc.
			float T = (P - 0.78f) / 0.22f;
			ContactR = ArcAround(ShR, StrikeR, FollowR, EaseOut(T));
			PoleR = ContactR + Up * 10.0f + Right * 12.0f;
			SinkBoost = 1.0f + 1.4f * (1.0f - T);
		}
		PalmR = (AimFlat * 0.7f - Up * 0.3f).GetSafeNormal().Rotation();

		// Small gather-dip as the toss goes up, legs extending through the strike.
		Crouch = 0.22f * Math::Sin(Math::Clamp(P / 0.7f, 0.0f, 1.0f) * PI);
	}
	else
	{
		// Poles leave the loop with the targets — same reason, same anchor.
		ContactR = ReadyR; ContactL = ReadyL;
		PoleR = ReadyShR - Up * 40.0f; PoleL = ReadyShL - Up * 40.0f;
	}

	// Ease from ready to the contact pose by the gesture weight. The spike/block/
	// serve build their own motion into ContactR/L (via SwingPhase/ServePhase), so
	// they should NOT be re-lerped from the ready pose (that would start the hand
	// at the hip instead of cocked/up). Bump/Set join them ONCE the real contact
	// swing is under way (Swing > 0): the generic gesture Blend is a 0->1->0 hump
	// that falls back toward 0 well before the 0.65s window ends (TargetPose =
	// Sin(Progress*PI) in VolleyballPlayer.as), so re-lerping toward ReadyR through
	// the second half of the follow-through fought the platform/cup's own EaseOut
	// swing-through — the hand target was being dragged back to the sides at the
	// same time the swing was still driving it further along the aim. That tug-
	// of-war (not upstream jitter) was the "flängigt" flailing in bagger/fingerslag:
	// spike/block/serve never had it because they were already exempt. Other
	// hits (still reaching, no contact yet) ease from ready as usual.
	FVector WantHandR;
	FVector WantHandL;
	bool bOwnMotion = Self.CurrentHit == EHitType::Hit_Spike || Self.CurrentHit == EHitType::Hit_Block
		|| Self.CurrentHit == EHitType::Hit_Serve
		|| ((Self.CurrentHit == EHitType::Hit_Bump || Self.CurrentHit == EHitType::Hit_Set) && Swing > 0.0f);
	if (bOwnMotion)
	{
		WantHandR = ContactR;
		WantHandL = ContactL;
	}
	else
	{
		// MinJerk on the gesture ramp: the reach leaves ready slowly, peaks
		// mid-travel and settles onto the platform/cup — constant-speed
		// interpolation here read as mechanical.
		float Ramp = MinJerk(Blend);
		WantHandR = ReadyR + (ContactR - ReadyR) * Ramp;
		WantHandL = ReadyL + (ContactL - ReadyL) * Ramp;
	}
	// No gesture: park effectors on the live hands so FBIK is a no-op and
	// the walk/run clip can play. The constructed Ready pose is in front
	// and down — leaving that as the target with IKAlpha=1 is what froze
	// every player in one reach silhouette.
	if (Blend < 0.05f)
	{
		FVector LiveR = Body.HandR;
		FVector LiveL = Body.HandL;
		FVector Actor = Self.GetActorLocation();
		if ((LiveR - Actor).SizeSquared() < 200.0f * 200.0f)
			WantHandR = LiveR;
		if ((LiveL - Actor).SizeSquared() < 200.0f * 200.0f)
			WantHandL = LiveL;
	}
	// A triggered through-swing on a genuine whip stroke (spike/serve set their
	// own, higher SinkBoost above) is deliberate ballistic motion worth opening
	// the sink for. The bump/set swing-through is a much smaller, slower motion
	// (a controlled platform sweep / cushion-then-drive, not a whip) that never
	// needed the wider cap to keep up with its OWN target — widening it here just
	// let ordinary frame-to-frame disagreement (meet-point re-prediction, crouch-
	// coupled shoulder shift) pass through at near full speed instead of being
	// smoothed, which read as a flailing dig/set. Leave bump/set at the base limit.
	if (Swing > 0.0f && Self.CurrentHit != EHitType::Hit_Bump && Self.CurrentHit != EHitType::Hit_Set)
		SinkBoost = Math::Max(SinkBoost, 1.0f + 1.2f * (1.0f - Swing));
	// Pose crouch plus whatever extra was requested — the deepest of the two
	// extra channels wins (held AI stance vs frame-rate transient), added on top
	// of the pose crouch, capped at full crouch. Max (not sum) between the extra
	// channels: a 0.45 planted stance and a 0.5 split-step dip are the SAME
	// lowering of the hips, not 0.95 of stacked bend.
	float ExtraC = Math::Max(Self.ExtraCrouch, Self.HeldCrouch);
	// Hard cap: beyond ~0.55 the folded thigh/shin has no room above the sand
	// and knees clip through. Bump's 0.5–0.7 knee key was the worst offender.
	//
	// GESTURE CROUCH vs GAIT: Reach starts early while still closing
	// (Plan.bStartGesture), so Crouch*Blend used to slam WantCrouch to the 0.55
	// cap mid-jog — same silhouette as "böjer sig framåt och backar" even when
	// facing was already fixed. Fade the POSE crouch with horizontal speed;
	// ExtraC (land absorb, dive, jump tuck) stays full — those are real.
	float CrouchSpeed = FVector(Self.PlayerVelocity.X, Self.PlayerVelocity.Y, 0).Size();
	float CrouchMoveFade = 1.0f - Math::Clamp((CrouchSpeed - 60.0f) / 140.0f, 0.0f, 1.0f);
	float PoseCrouch = Crouch * Blend * CrouchMoveFade;
	float WantCrouch = Math::Clamp(PoseCrouch + ExtraC, 0.0f, 0.55f);
	Self.DbgPoseCrouch = PoseCrouch;
	Self.DbgWantCrouch = WantCrouch;

	// --- ANTI-FLICKER GUARD (the sink) --------------------------------------
	// Everything the ABP sees passes through HERE with a speed limit, so no
	// upstream disagreement can ever alternate the pose between two solutions
	// at frame rate again — such a conflict now collapses into a small wobble
	// around the midpoint instead of a two-pose teleport. The limits sit far
	// above legitimate gesture speeds (fastest whip ≈ 600-800cm/s), so real
	// choreography passes through untouched.
	if (!Self.bSmInit)
	{
		Self.bSmInit = true;
		Self.SmHandVelR = FVector::ZeroVector;
		Self.SmHandVelL = FVector::ZeroVector;
		Self.SmHandR = WantHandR; Self.SmHandL = WantHandL;
		Self.SmPoleR = PoleR;     Self.SmPoleL = PoleL;
		Self.SmRotR  = PalmR;     Self.SmRotL  = PalmL;
		Self.SmCrouch = WantCrouch;
	}
	// Base limit covers held poses and repositioning; SinkBoost opens it for
	// deliberate swings (a real spike hand peaks 15-20+ m/s — capping the whip
	// at the anti-flicker limit was robbing every strike of its snap). The
	// motion monitor reads SinkBoostLog so its teleport check tracks the
	// same ceiling.
	float MaxStep = 900.0f * SinkBoost * Dt;
	Self.SinkBoostLog = SinkBoost;
	// Hands go through the acceleration-limited sink; the poles and the palm
	// keep the plain speed clamp, since an elbow hint reversing is not something
	// the eye reads as a jolt the way the hand is.
	float MaxSpeed = 900.0f * SinkBoost;
	float MaxAccel = HandSinkAccel * SinkBoost;
	Self.SmHandR = MoveTowardAccel(Self.SmHandR, Self.SmHandVelR, WantHandR,
		MaxSpeed, MaxAccel, Dt);
	Self.SmHandL = MoveTowardAccel(Self.SmHandL, Self.SmHandVelL, WantHandL,
		MaxSpeed, MaxAccel, Dt);
	// Passthrough must be exact: a leftover Ready target lerping in still
	// folds the spine for a beat after every gesture. The stored velocity has to
	// die with it, or the next gesture starts by carrying the old one.
	if (Blend < 0.05f)
	{
		Self.SmHandR = WantHandR;
		Self.SmHandL = WantHandL;
		Self.SmHandVelR = FVector::ZeroVector;
		Self.SmHandVelL = FVector::ZeroVector;
		Self.SmPlatDir = FVector::ZeroVector;
		Self.GestureClock = 0.0f;
	}
	Self.SmPoleR = MoveTowardClamped(Self.SmPoleR, PoleR, MaxStep);
	Self.SmPoleL = MoveTowardClamped(Self.SmPoleL, PoleL, MaxStep);
	// Wrist keeps pace with the hand: the palm SNAPS through contact at swing
	// speed (kinetic chain: the wrist is the last, fastest link).
	float RotAlpha = Math::Clamp(14.0f * SinkBoost * Dt, 0.0f, 1.0f);
	Self.SmRotR = Math::LerpShortestPath(Self.SmRotR, PalmR, RotAlpha);
	Self.SmRotL = Math::LerpShortestPath(Self.SmRotL, PalmL, RotAlpha);
	// PROPORTIONAL rate (exponential approach), NOT a rate clamp: the old
	// clamp moved at its full limit rate (-1.5/+6.0 per s) for ANY error
	// beyond a 0.04 deadband, so the ±0.04 upstream zigzag (9Hz meet-point
	// re-prediction, extra-crouch re-asserts) became full-rate knee flapping
	// — the residual crouchFlips class that survived every source-side fix
	// (stats22-26; the CFLIP dumps show rate pinned at exactly -1.5/+6.0
	// with |want-sm| ≈ 0.04). Rate ∝ error makes micro-noise yield micro-
	// rates (0.04·8 = 0.32/s) while real intent changes (err 0.3+) still
	// sink athletically (2.4+/s). Asymmetry kept: sinking fast (dives,
	// landings), rising lazy — a slow release reads as a held stance.
	float CrouchErr = WantCrouch - Self.SmCrouch;
	float CrouchGain = (CrouchErr > 0.0f) ? 8.0f : 3.0f;
	Self.SmCrouch += CrouchErr * Math::Min(CrouchGain * Dt, 1.0f);

	Self.Anim.HandTargetR  = Self.SmHandR;
	Self.Anim.HandTargetL  = Self.SmHandL;
	Self.Anim.ElbowPoleR   = Self.SmPoleR;
	Self.Anim.ElbowPoleL   = Self.SmPoleL;
	Self.Anim.HandRotR     = Self.SmRotR;
	Self.Anim.HandRotL     = Self.SmRotL;
	// Airborne crouch is what made jump silhouettes go up butt-first: a sunk
	// pelvis under a rising capsule. Force the stance upright in the air.
	if (!Self.bIsGrounded)
		Self.SmCrouch = Math::Min(Self.SmCrouch, 0.05f);
	Self.Anim.CrouchAmount = Self.SmCrouch;

	// Pelvis sink target: lower it from its rest height by CrouchAmount. Anchored
	// to ActorLocation (physics-authoritative), NOT a live pelvis bone — the same
	// reason ReadyShR/L anchor to the actor instead of the shoulder bones above:
	// bone-anchoring here would close a loop through the Modify Bone node's own
	// output (pelvis moves -> next frame reads a lower pelvis -> target drops
	// further). +5.9cm is the measured rest offset from actor origin to the
	// pelvis bone in the reference pose (capsule origin sits at hip height,
	// pelvis is a hair above it).
	//
	// The ABP pulls the pelvis rigidly to this point (Modify Bone, world space,
	// Replace) which on its own would drag the whole skeleton down and sink the
	// feet through the floor. FootTargetL/R below hold the *previous* frame's
	// solved foot position; Two Bone IK re-targets each leg back to that fixed
	// point after the pelvis moves, so the knees bend to keep the foot planted
	// instead of the foot sliding with the hip. One frame of lag is invisible
	// at crouch speed and self-stabilizes once the pelvis stops moving.
	const float PelvisRestZ = 5.9f;
	const float PelvisSinkDepth = 35.0f;  // cm of hip drop at full CrouchAmount
	// Never sink the pelvis so low that a bent knee has nowhere to go but
	// through the floor (deep crouch + plant put knees under the sand).
	const float MinPelvisClearance = 42.0f;   // cm above FloorZ
	FVector PelvisPlant = Self.GetActorLocation() + Up * (PelvisRestZ - PelvisSinkDepth * Self.SmCrouch);
	float MinPelvisZ = Self.FloorZ + MinPelvisClearance;
	if (PelvisPlant.Z < MinPelvisZ)
		PelvisPlant.Z = MinPelvisZ;
	// Echo last frame's solved foot position back as this frame's target (as
	// above), rotated by this frame's yaw change and CLAMPED to a plausible
	// stance around the actor. Both corrections are needed and they fix
	// different halves of the same failure:
	//
	//  - ROTATION. A pure echo pins the feet in WORLD space: fine standing
	//    still, but a fast yaw turn (AI "DEFEND SPLIT" repositioning hits
	//    300+ deg/s) rotates the torso out from under feet that don't follow,
	//    dragging the leg across the body — the "legs crossing" symptom.
	//    Pivoting around the actor's CURRENT location makes this a no-op at
	//    DYaw 0, so straight-line movement keeps the plain echo's behavior.
	//
	//  - DRIFT. The echo is a feedback loop with NO GROUND ANCHOR: the target
	//    is only ever "where the foot ended up", so nothing in it asserts that
	//    feet belong under the body on the sand. Every source of drift — the
	//    pelvis sinking on crouch, arm IK pulling the torso, a frame of solver
	//    error — is written straight back as the next target and accumulates,
	//    ending with the legs pointing horizontally out in front and the feet
	//    dangling in the air. The old 200cm guard only caught a total blow-up
	//    (the not-yet-posed zero vector), never a steady drift.
	//
	// The clamp below is the missing anchor: pull the target back onto the
	// floor plane and keep it inside a stance radius of the actor. Both are
	// no-ops for a foot that IS planted sensibly, so the "foot holds still
	// while the body moves over it" behavior a plain echo gets for free
	// survives — that behavior is what kept footSlide low, and the three
	// alternatives that recomputed the foot from scratch each frame all
	// destroyed it (measured footSlide 900-3900/rally, i.e. skating).
	if (!Self.bFootYawInit)
	{
		Self.bFootYawInit = true;
		Self.PrevYawForFeet = Self.GetActorRotation().Yaw;
	}
	float CurYaw = Self.GetActorRotation().Yaw;
	float DYaw = Math::FindDeltaAngleDegrees(Self.PrevYawForFeet, CurYaw);
	FRotator YawDelta = FRotator(0.0f, DYaw, 0.0f);
	FVector ActorLoc = Self.GetActorLocation();
	FVector PlantL = GroundFootTarget(Self, ActorLoc + YawDelta.RotateVector(FootL - ActorLoc), ActorLoc, Right);
	FVector PlantR = GroundFootTarget(Self, ActorLoc + YawDelta.RotateVector(FootR - ActorLoc), ActorLoc, -Right);

	// FADE THE PLANT OUT WHEN THERE IS NO CROUCH TO SERVE.
	//
	// The plant above is a crouch tool: it holds the feet still so a sinking
	// pelvis has to fold the knees. That is right for a receive and wrong for
	// a walk — the target is clamped to a stance radius around the hips, so a
	// walking player's legs get pinned under the body, the stride never
	// happens, and the only bones left moving are the toes (below the IK'd
	// foot, still driven by the base clip). That is the "they only move their
	// toes when they walk" report.
	//
	// The Two Bone IK nodes have an Alpha pin for exactly this, but nothing
	// can create AnimGraph nodes to drive it (no Python API for EdGraph node
	// creation, and the MCP add-node tool only reaches the EventGraph). The
	// same blend is available here for free: lerping the TARGET toward the
	// foot's own current animated position is identical to lerping the node's
	// weight, because at alpha 0 the solver is asked for the pose it already
	// has and does nothing. FootL/FootR are that animated position — this
	// frame's live bone read, taken above.
	//
	// SPEED IS THE GATE, NOT CROUCH DEPTH. Keying this on crouch alone does
	// not work: the AI holds a 0.18-0.30 athletic stance crouch permanently
	// while repositioning (RequestCrouch sits right next to MoveToHold in
	// AIPlayer.as), so a crouch-only fade stays near full weight during every
	// walk and the legs stay pinned. A planted foot is only meaningful when
	// the player is not travelling: once they are, the gait has to own the
	// legs no matter how deep the stance is. Fade out across 30-80 cm/s (was
	// 40-120). The old window left ~25% plant weight up to 120 cm/s; the AI
	// repositions at ~100 while holding a 0.18-0.30 athletic crouch, so feet were
	// partially pinned during every jog — measured footSlide 900+ even with the
	// blendspace wired. A standing receive below 30 cm/s keeps full plant;
	// anything above 80 is pure gait animation.
	float PlantSpeed = FVector(Self.PlayerVelocity.X, Self.PlayerVelocity.Y, 0).Size();
	// Walk clip lives at ~175 cm/s. The old 30–80 fade left plant weight on
	// through the whole shuffle/walk band, so the Two Bone IK pinned the
	// feet and "vanlig gång" was a slide with twitching toes.
	float MoveFade = 1.0f - Math::Clamp((PlantSpeed - 15.0f) / 25.0f, 0.0f, 1.0f);
	// Plant/pelvis Modify Bone is a GROUNDED crouch tool. Leaving it on in the
	// air (jump-load crouch) pins a sunk pelvis under a rising capsule — the
	// silhouette goes up butt-first. Dive/ragdoll own the body through bDiving
	// + physics blend; never fight them with a pelvis plant.
	if (!Self.bIsGrounded || Self.IsDiving() || Self.bRagdollActive)
		MoveFade = 0.0f;
	float PlantAlpha = Math::Clamp(Self.SmCrouch / 0.25f, 0.0f, 1.0f) * MoveFade;

	const float MinFootZ = Self.FloorZ + 2.0f;
	// Ankle bones rest around Z≈3–6 on this mesh (measured via POSE telemetry).
	// FloorZ+12 falsely flagged every idle frame as under-sand and forced
	// LegIKAlpha=1 permanently → skating. Only lift when a bone is truly buried.
	float FloorFix = 0.0f;
	// Never steal the gait: a walk cycle dips an ankle below MinFootZ every
	// step, and FloorFix=1 pinned that foot → slide. Lift only while planted.
	if (Self.bIsGrounded && !Self.bRagdollActive && MoveFade > 0.5f)
	{
		if (FootL.Z < MinFootZ || FootR.Z < MinFootZ)
			FloorFix = 1.0f;
	}

	float FootAlpha = Math::Max(PlantAlpha, FloorFix);

	// A PLANTED FOOT IS A POINT ON THE SAND. PlantL/PlantR above are derived from
	// FootL/FootR — the solver's own output from last frame — rotated about the
	// actor and grounded. So the "plant" the foot is pulled toward is recomputed
	// every frame FROM WHERE THE FOOT ALREADY IS, at every alpha including 1. The
	// foot is never pinned to anything; it is pinned to itself, and the loop
	// walked the goals 146cm under the body during a single dig.
	//
	// Latch the point instead: capture it the frame the plant starts and hold it
	// in world space until the plant releases, which is what standing on a spot
	// means. (Latching the ALPHA was tried first and made it worse — 146 -> 188cm
	// — because both branches of the blend still read the live bone.)
	// ...and A FOOT SLIPS WHEN YOU PULL HARD ENOUGH. Holding the point no matter
	// what pins a player who still needs to go somewhere, and the first version
	// of this cost rallies: dead-after-one-touch 0% -> 5-7%, builds 100% -> 93-95%.
	// Re-plant once the leg has genuinely travelled past the held point, which is
	// what taking a step is.
	const float PlantBreakDist = 30.0f;
	if (FootAlpha > 0.001f)
	{
		if (!Self.bPlantHeld
			|| (PlantL - Self.PlantHoldL).Size() > PlantBreakDist
			|| (PlantR - Self.PlantHoldR).Size() > PlantBreakDist)
		{
			Self.PlantHoldL = PlantL;
			Self.PlantHoldR = PlantR;
			Self.bPlantHeld = true;
		}
		PlantL = Self.PlantHoldL;
		PlantR = Self.PlantHoldR;
	}
	else
	{
		Self.bPlantHeld = false;
	}

	Self.Anim.LegIKAlpha = FootAlpha;
	FVector OutFootL = FootL + (PlantL - FootL) * FootAlpha;
	FVector OutFootR = FootR + (PlantR - FootR) * FootAlpha;
	if (Self.bIsGrounded)
	{
		if (OutFootL.Z < MinFootZ) OutFootL.Z = MinFootZ;
		if (OutFootR.Z < MinFootZ) OutFootR.Z = MinFootZ;
	}
	Self.Anim.FootTargetL = OutFootL;
	Self.Anim.FootTargetR = OutFootR;

	// THE PELVIS IS THE ONE THAT ACTUALLY BROKE THE WALK. Modify Bone replaces
	// the pelvis with PelvisTarget in WORLD space at full weight every frame,
	// so the hips are pinned to the capsule wherever the animation wanted to
	// put them. A walk cycle drives the whole leg swing from hip motion, so
	// pinning the hips flattens the gait to nothing and leaves only the bones
	// below the IK — feet and toes — visibly moving. Fading the FEET alone
	// (the first two attempts) could never fix that, because the feet were
	// never the thing overriding the walk.
	//
	// PelvisTarget is PelvisPlant, full stop — no script-side blend toward the
	// pelvis bone's own animated position. That blend trick used to exist here
	// to fade the node to a no-op without an Alpha pin, but the ModifyBone
	// node's Alpha IS wired to LegIKAlpha (this same PlantAlpha, via
	// Anim.LegIKAlpha below) now, so it already fades rawPose -> PelvisTarget
	// at the graph level. Blending toward Mesh.GetBoneTransform(pelvis) on top
	// of that closed a feedback loop the ActorLocation-anchored PelvisPlant
	// above was specifically built to avoid (see that comment): that read
	// returns THIS node's own output from last frame, which self-reinforces
	// at any nonzero alpha. Removed on principle, not as a confirmed fix for
	// any specific symptom — traced telemetry during an unrelated idle-pose
	// investigation showed PlantAlpha pinned at exactly 0.0 (WantCrouch never
	// leaves 0 while grounded and stationary), so this path was provably inert
	// in that case. The wobble under investigation there is still unexplained.
	Self.Anim.PelvisTarget = PelvisPlant;
	Self.PrevYawForFeet = CurYaw;
}

// Anchor an echoed foot target to something anatomically possible: on the
// sand (or at the feet while airborne), and within a stride of the hips.
// Without this the echo loop has no term pulling the feet groundward at all
// and drifts until the legs stick straight out in front of the body.
FVector GroundFootTarget(AVolleyballPlayer Self, FVector Target, FVector ActorLoc, FVector SideDir)
{
	// Where this foot SHOULD be: under the hips, out to its own side, on the
	// floor. While airborne the feet hang under the (raised) actor instead of
	// reaching for distant sand, so a jump doesn't stretch the legs downward.
	const float StanceWidth = 12.0f;
	// Ankle bone, not sole — see FootSoleZ note at PelvisPlant.
	const float FootSoleZ = 5.0f;
	float PlantZ = Self.bIsGrounded
		? (Self.FloorZ + FootSoleZ)
		: (ActorLoc.Z - Self.PlayerHeight + FootSoleZ);
	FVector Rest = FVector(ActorLoc.X, ActorLoc.Y, PlantZ) + SideDir * StanceWidth;

	// Feet live on the floor plane: a planted foot has no business floating,
	// and this is the term the echo loop was missing entirely.
	FVector Planted = FVector(Target.X, Target.Y, PlantZ);

	// ...and within one stride of the hips, so an accumulated horizontal
	// drift can't march the target out past what a leg can reach. Inside the
	// radius this changes nothing, which is what preserves the plant.
	//
	// Measured HORIZONTALLY (XY only) on purpose. THE KNEE BEND DEPENDS ON
	// THIS: a crouch works by the pelvis sinking while the foot stays put, so
	// Two Bone IK has to fold the knee to span the shortened hip-to-foot gap.
	// Clamping the full 3D distance to the hips instead holds that gap
	// roughly constant, which straightens the leg again and cancels the
	// crouch entirely — the legs stopped bending at all. Only the horizontal
	// wander is drift worth correcting; the vertical gap IS the crouch.
	const float MaxStride = 55.0f;
	FVector Offset = FVector(Planted.X - Rest.X, Planted.Y - Rest.Y, 0.0f);
	float Dist = Offset.Size();
	if (Dist > MaxStride)
	{
		FVector Clamped = Rest + Offset * (MaxStride / Dist);
		Planted = FVector(Clamped.X, Clamped.Y, PlantZ);
	}
	return Planted;
}

// --- FIRST-PRINCIPLES MOTION SHAPING ---------------------------------------
// Real limb motion is never constant-speed. Three time profiles cover every
// gesture segment, chosen by what the segment IS:
//  - MinJerk: a self-contained reach (cock, toss, platform set-up) — the
//    minimum-jerk law (Flash & Hogan): bell velocity, slow-fast-slow.
//  - EaseIn: a segment ENDING at contact — the hand must pass through the
//    ball at PEAK speed (a whip), never decelerating into it.
//  - EaseOut: follow-through — starts at strike speed, bleeds off naturally.
float MinJerk(float T)
{
	float C = Math::Clamp(T, 0.0f, 1.0f);
	return C * C * C * (10.0f + C * (6.0f * C - 15.0f));
}
float EaseIn(float T)
{
	float C = Math::Clamp(T, 0.0f, 1.0f);
	return C * C;
}
float EaseOut(float T)
{
	float C = Math::Clamp(T, 0.0f, 1.0f);
	return 1.0f - (1.0f - C) * (1.0f - C);
}

// Hands sweep ARCS around the shoulder, not chords between waypoints: nlerp
// the direction from the pivot and lerp the radius. A straight-line hand
// path is the giveaway of keyframe interpolation; the arc is what a hinged
// arm physically does.
FVector ArcAround(FVector Pivot, FVector A, FVector B, float T)
{
	FVector DA = A - Pivot;
	FVector DB = B - Pivot;
	float RA = DA.Size();
	float RB = DB.Size();
	if (RA < 1.0f || RB < 1.0f) return A + (B - A) * T;
	FVector Dir = (DA / RA + (DB / RB - DA / RA) * T).GetSafeNormal();
	return Pivot + Dir * (RA + (RB - RA) * T);
}

// THE SINK'S SECOND LIMIT: acceleration.
//
// MoveTowardClamped below caps how far an effector may travel in a frame and
// nothing else, so it has no memory of which way the hand was already going. A
// target that flips hand the hand reverses at the FULL speed cap in a single
// frame — 900cm/s one way, 900cm/s the other, no deceleration in between. That
// is what "stötiga slaganimationer" is, and it is invisible to the teleport
// monitor because the speed limit was never broken. Measured over three runs:
// 8878 direction reversals past 90 degrees inside hit gestures, worst 178, and
// the samples show both sides of the reversal pinned at the cap.
//
// A limb cannot do that. It has to bleed off the speed it has before it can
// build speed the other way, so the hand carries a velocity and the velocity
// itself is rate-limited. Speed cap unchanged; SinkBoost opens both, so a whip
// still snaps.
FVector MoveTowardAccel(FVector From, FVector& Vel, FVector To,
	float MaxSpeed, float MaxAccel, float Dt)
{
	if (Dt <= 0.0f) return From;
	// The velocity that would land exactly on the target this frame, capped.
	FVector Want = (To - From) / Dt;
	float WantSpeed = Want.Size();
	if (WantSpeed > MaxSpeed) Want *= (MaxSpeed / WantSpeed);
	// ...approached under an acceleration limit rather than adopted outright.
	FVector DV = Want - Vel;
	float DVLen = DV.Size();
	float MaxDV = MaxAccel * Dt;
	if (DVLen > MaxDV && DVLen > 0.0001f) DV *= (MaxDV / DVLen);
	Vel += DV;
	FVector Next = From + Vel * Dt;
	// Never overshoot the target: if the step would carry past it, land on it
	// and drop the velocity to what the remaining distance justifies.
	FVector ToTarget = To - From;
	if (ToTarget.SizeSquared() > 0.0001f
		&& (Next - From).SizeSquared() > ToTarget.SizeSquared())
	{
		Vel = ToTarget / Dt;
		float VS = Vel.Size();
		if (VS > MaxSpeed) Vel *= (MaxSpeed / VS);
		return To;
	}
	return Next;
}

// Move From toward To by at most MaxStep (cm) — the sink's speed limiter.
FVector MoveTowardClamped(FVector From, FVector To, float MaxStep)
{
	FVector D = To - From;
	float L = D.Size();
	if (L <= MaxStep || L < 0.001f) return To;
	return From + D * (MaxStep / L);
}
