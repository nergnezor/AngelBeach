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
mixin void UpdateIKTargets(AVolleyballPlayer Self, float Blend, float Dt)
{
	if (Self.Mesh == nullptr) return;

	// Body anchors from the actual skeleton (track jumps, lean, run).
	FVector Head  = Self.Mesh.GetBoneTransform(n"head").Location;
	FVector ShR   = Self.Mesh.GetBoneTransform(n"upperarm_r").Location;
	FVector ShL   = Self.Mesh.GetBoneTransform(n"upperarm_l").Location;
	// Last frame's solved foot position — this frame's Two Bone IK target, so a
	// moving pelvis (crouch) doesn't drag the feet through the ground with it.
	FVector FootL = Self.Mesh.GetBoneTransform(n"foot_l").Location;
	FVector FootR = Self.Mesh.GetBoneTransform(n"foot_r").Location;
	FVector Fwd   = Self.GetActorForwardVector();
	FVector Right = Self.GetActorRightVector();
	// Guard against a not-yet-posed mesh: before the very first Anim Blueprint
	// evaluation, GetBoneTransform returns the zero vector, which (being far
	// from the actor, wherever it's spawned) is a wildly degenerate Two Bone IK
	// target — the leg stretches toward world origin, and because the target
	// is "read last frame's result", that bad pose is then self-reinforcing
	// instead of self-correcting. Fall back to an approximate ground position
	// under the actor whenever the read foot is implausibly far away.
	FVector FootFallback = Self.GetActorLocation() - FVector(0, 0, 90.0f);
	if ((FootL - Self.GetActorLocation()).SizeSquared() > 200.0f * 200.0f)
		FootL = FootFallback;
	if ((FootR - Self.GetActorLocation()).SizeSquared() > 200.0f * 200.0f)
		FootR = FootFallback;
	FVector Up    = FVector(0, 0, 1);

	// Where the player is sending the ball. Falls back to "up and forward".
	FVector Aim = Self.bHasAim
		? (Self.DesiredAim - Head).GetSafeNormal()
		: (Fwd * 0.4f + Up).GetSafeNormal();
	FVector AimFlat = FVector(Aim.X, Aim.Y, 0).GetSafeNormal();
	if (AimFlat.SizeSquared() < 0.01f) AimFlat = Fwd;

	// Where the BALL is — the hands reach straight toward it, clamped to arm's
	// length from the chest so the IK stays solvable. The player turns to face the
	// ball (FaceBall in the AI), so this naturally ends up in front.
	FVector ChestMid = (ShR + ShL) * 0.5f;
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

	// 0 -> 1 over the contact swing (TriggerHit envelope): lets poses swing
	// THROUGH the ball along the aim at contact instead of freezing on it.
	float Swing = Self.SwingProgress();

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
		FVector PlatformBall = BallContact;
		{
			ABall PB = Self.GetWorldBall();
			if (PB != nullptr && PB.bInPlay && Self.bHasPredictedMeetLow
				&& PB.Position.Z > Self.PredictedMeetLow.Z + 30.0f)
			{
				FVector ToMeet = Self.PredictedMeetLow - ChestMid;
				PlatformBall = (ToMeet.Size() > 110.0f)
					? ChestMid + ToMeet.GetSafeNormal() * 110.0f
					: Self.PredictedMeetLow;
			}
		}
		FVector Platform = PlatformBall - Up * 12.0f;
		FVector PlatDir = (Platform - ChestMid).GetSafeNormal();
		if (PlatDir.SizeSquared() < 0.01f) PlatDir = Fwd - Up;
		float Ext = Math::Max((Platform - ChestMid).Size(), 96.0f);  // lock the elbows out
		FVector PlatEnd = ChestMid + PlatDir * Ext;
		// At contact the platform SWINGS THROUGH the ball, lifting along the aim —
		// a bagger is a controlled swing from the shoulders, not a held tray.
		// EaseOut: the through-swing starts at contact speed and bleeds off.
		PlatEnd += (AimFlat * 26.0f + Up * 18.0f) * EaseOut(Swing);
		ContactR = PlatEnd - Right * 5.0f;
		ContactL = PlatEnd + Right * 5.0f;
		// Elbow hints sit ON the shoulder->hand line, nudged down/in, so the IK
		// keeps the arms straight instead of chicken-winging them outward.
		PoleR = ShR + PlatDir * 45.0f - Up * 22.0f - Right * 6.0f;
		PoleL = ShL + PlatDir * 45.0f - Up * 22.0f + Right * 6.0f;
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
		{
			ABall KB = Self.GetWorldBall();
			if (KB != nullptr && KB.bInPlay)
			{
				KneeKeyZ = (Self.bHasPredictedMeetLow
							&& KB.Position.Z > Self.PredictedMeetLow.Z + 30.0f)
					? Self.PredictedMeetLow.Z
					: KB.Position.Z;
			}
		}
		float FeetZ = Self.GetActorLocation().Z - Self.PlayerHeight;
		float ContactAboveFeet = KneeKeyZ - FeetZ;
		float BallLow = Math::Clamp((110.0f - ContactAboveFeet) / 80.0f, 0.0f, 1.0f);
		Crouch = 0.5f + 0.2f * BallLow;
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
		FVector CupBall = BallContact;
		{
			ABall SB2 = Self.GetWorldBall();
			if (SB2 != nullptr && SB2.bInPlay && Self.bHasPredictedMeetHigh
				&& SB2.Position.Z > Self.PredictedMeetHigh.Z + 30.0f)
			{
				FVector ToMeet = Self.PredictedMeetHigh - ChestMid;
				CupBall = (ToMeet.Size() > 110.0f)
					? ChestMid + ToMeet.GetSafeNormal() * 110.0f
					: Self.PredictedMeetHigh;
			}
		}
		FVector Cup = CupBall - Up * 6.0f;                   // finger window just under the ball
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
		PoleR = ShR + Fwd * 30.0f + Right * 18.0f + Up * 4.0f;
		PoleL = ShL + Fwd * 30.0f - Right * 18.0f + Up * 4.0f;
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

		float SwingPhase = Blend;
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
	float WantCrouch = Math::Clamp(Crouch * Blend + ExtraC, 0.0f, 1.0f);
	Self.DbgPoseCrouch = Crouch * Blend;
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
	Self.SmHandR = MoveTowardClamped(Self.SmHandR, WantHandR, MaxStep);
	Self.SmHandL = MoveTowardClamped(Self.SmHandL, WantHandL, MaxStep);
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
	Self.Anim.PelvisTarget = Self.GetActorLocation() + Up * (PelvisRestZ - PelvisSinkDepth * Self.SmCrouch);
	// Echo last frame's solved foot position back as this frame's target (as
	// above) — EXCEPT rotate the actor-relative offset by this frame's yaw
	// change first. A pure echo (no rotation correction) pins the feet in
	// WORLD space: fine while standing still, but a fast yaw turn (AI
	// "DEFEND SPLIT" repositioning hits 300+ deg/s) rotates the torso out from
	// under feet that don't follow, dragging the leg across the body every
	// frame it's turning — the reported "legs crossing" bug, measured as
	// pelvisFlips up to 32/rally on exactly those players.
	//
	// Pivoting the echoed point around the actor's CURRENT location (not
	// tracking the actor's translation separately) makes this a no-op when
	// DYaw is 0 — FootTarget reduces to exactly FootL, byte-for-byte the
	// original echo — so straight-line movement keeps that system's already
	// -verified translation behavior untouched. Two tried alternatives that
	// derived the foot target fresh from the actor's transform every frame
	// (zero lag on translation too, not just rotation) instead measured
	// footSlide 900-3900/rally, i.e. skating: Two Bone IK's own reach limit is
	// what gives a plain echo its "foot holds still while planted, body moves
	// over it, catches up only once the leg is fully stretched" behavior, and
	// both alternatives threw that away along with the rotation bug.
	if (!Self.bFootYawInit)
	{
		Self.bFootYawInit = true;
		Self.PrevYawForFeet = Self.GetActorRotation().Yaw;
	}
	float CurYaw = Self.GetActorRotation().Yaw;
	float DYaw = Math::FindDeltaAngleDegrees(Self.PrevYawForFeet, CurYaw);
	FRotator YawDelta = FRotator(0.0f, DYaw, 0.0f);
	FVector ActorLoc = Self.GetActorLocation();
	Self.Anim.FootTargetL = ActorLoc + YawDelta.RotateVector(FootL - ActorLoc);
	Self.Anim.FootTargetR = ActorLoc + YawDelta.RotateVector(FootR - ActorLoc);
	Self.PrevYawForFeet = CurYaw;
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

// Move From toward To by at most MaxStep (cm) — the sink's speed limiter.
FVector MoveTowardClamped(FVector From, FVector To, float MaxStep)
{
	FVector D = To - From;
	float L = D.Size();
	if (L <= MaxStep || L < 0.001f) return To;
	return From + D * (MaxStep / L);
}
