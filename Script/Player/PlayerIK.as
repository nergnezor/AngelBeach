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
	FVector Fwd   = Self.GetActorForwardVector();
	FVector Right = Self.GetActorRightVector();
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
	FVector ReadyR = ShR + Fwd * 18.0f - Up * 35.0f;
	FVector ReadyL = ShL + Fwd * 18.0f - Up * 35.0f;

	FVector ContactR;
	FVector ContactL;
	FRotator PalmR = FRotator::ZeroRotator;
	FRotator PalmL = FRotator::ZeroRotator;
	FVector PoleR;
	FVector PoleL;
	float Crouch = 0.0f;

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
		PlatEnd += (AimFlat * 26.0f + Up * 18.0f) * Swing;
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
		float FeetZ = Self.GetActorLocation().Z - Self.PlayerHeight;
		float PlatAboveFeet = PlatEnd.Z - FeetZ;
		float BallLow = Math::Clamp((110.0f - PlatAboveFeet) / 80.0f, 0.0f, 1.0f);
		Crouch = 0.5f + 0.2f * BallLow;
	}
	else if (Self.CurrentHit == EHitType::Hit_Set)
	{
		// Fingerpass/set: hands form a CUP under/around the ball above the brow,
		// elbows forward. At contact the arms EXTEND fully through the ball toward
		// the aim (the wrist/elbow extension is what a set's power comes from).
		// Same park-at-the-meet-point trick as the bump: the cup waits where the
		// ball will cross brow height instead of chasing it down.
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
		FVector Cup = CupBall - Up * 6.0f;                   // hands just under the ball
		FVector Push = (AimFlat * 0.6f + Up * 0.8f).GetSafeNormal();
		FVector Extend = Push * (6.0f * Blend + 26.0f * Swing);
		ContactR = Cup - Right * 11.0f + Extend;
		ContactL = Cup + Right * 11.0f + Extend;
		// Elbows point FORWARD (and slightly out) — the set's signature shape.
		PoleR = ShR + Fwd * 40.0f - Right * 10.0f;
		PoleL = ShL + Fwd * 40.0f + Right * 10.0f;
		PalmR = (AimFlat * 0.5f + Up).GetSafeNormal().Rotation();
		PalmL = PalmR;
		Crouch = 0.2f;
	}
	else if (Self.CurrentHit == EHitType::Hit_Spike)
	{
		// Spike — the real arm choreography, driven by how far the ball has
		// DESCENDED toward the strike point (SwingPhase 0 = loading, 1 = contact):
		//  - RIGHT arm: backswing (hand low behind the hip) -> cocked (outside the
		//    right cheek) -> strike (above/in front of the shoulder).
		//  - LEFT arm: the timing arm. POINTS at the ball through the windup, then
		//    PULLS DOWN to the ribs as the right whips through — the counter-
		//    rotation every real hitter uses for power. A left arm that keeps
		//    pointing through contact is the tell of a video-game spike.
		FVector BackSw = ShR - Fwd * 30.0f - Up * 30.0f + Right * 20.0f;  // behind the hip
		FVector Cheek  = Head + Right * 22.0f + Up * 2.0f - Fwd * 8.0f;   // outside right cheek
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
		FVector Strike = ShR + Up * StrikeUp + Fwd * 22.0f + Right * 6.0f; // above & front of R shoulder

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

		// Left arm: point at the ball, then tuck hard as the swing comes through.
		FVector ToBallL = (BallContact - ShL);
		float ReachL = 95.0f;
		if (ToBallL.Size() > ReachL) ToBallL = ToBallL.GetSafeNormal() * ReachL;
		FVector PointL = ShL + ToBallL;
		FVector TuckL  = ShL - Up * 28.0f + Fwd * 12.0f;   // elbow-down tuck at the ribs
		if (SwingPhase < 0.55f)
		{
			ContactL = PointL;
			PoleL = ShL + ToBallL * 0.4f - Up * 15.0f;     // elbow softly under the aim line
			PalmL = ToBallL.GetSafeNormal().Rotation();
		}
		else
		{
			float Pull = (SwingPhase - 0.55f) / 0.45f;
			ContactL = PointL + (TuckL - PointL) * Pull;
			PoleL = ShL - Up * 20.0f - Fwd * 10.0f;        // elbow folds down/back
			PalmL = (-Up).Rotation();
		}

		if (SwingPhase < 0.45f)
			ContactR = BackSw + (Cheek - BackSw) * (SwingPhase / 0.45f);
		else
			ContactR = Cheek + (Strike - Cheek) * ((SwingPhase - 0.45f) / 0.55f);
		// Elbow stays high and back early, leading the hand on the swing.
		PoleR = ContactR + Up * 25.0f - Fwd * 30.0f + Right * 10.0f;
		// Palm faces the aim/down as it comes over the top.
		PalmR = (AimFlat * 0.5f + Up * (1.0f - SwingPhase) - Up * 0.3f * SwingPhase).GetSafeNormal().Rotation();
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
			ContactL = TossStart + (TossHand - TossStart) * (T * T * (3.0f - 2.0f * T)); // smoothstep lift
			PoleL = ShL + Fwd * 35.0f - Up * 4.0f;
			PalmL = Up.Rotation();                    // palm up, carrying the ball
		}
		else
		{
			float T = (P - 0.6f) / 0.4f;
			ContactL = TossHand + (TuckL - TossHand) * T;
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
			float T = P / 0.55f;
			ContactR = RestR + (DrawR - RestR) * (T * T);
			PoleR = ContactR + Up * 20.0f - Fwd * 25.0f + Right * 12.0f;
		}
		else if (P < 0.78f)
		{
			float T = (P - 0.55f) / 0.23f;
			ContactR = DrawR + (StrikeR - DrawR) * T;
			PoleR = ContactR + Up * 18.0f - Fwd * 20.0f + Right * 10.0f;
		}
		else
		{
			float T = (P - 0.78f) / 0.22f;
			ContactR = StrikeR + (FollowR - StrikeR) * T;
			PoleR = ContactR + Up * 10.0f + Right * 12.0f;
		}
		PalmR = (AimFlat * 0.7f - Up * 0.3f).GetSafeNormal().Rotation();

		// Small gather-dip as the toss goes up, legs extending through the strike.
		Crouch = 0.22f * Math::Sin(Math::Clamp(P / 0.7f, 0.0f, 1.0f) * PI);
	}
	else
	{
		ContactR = ReadyR; ContactL = ReadyL;
		PoleR = ShR - Up * 40.0f; PoleL = ShL - Up * 40.0f;
	}

	// Ease from ready to the contact pose by the gesture weight. The spike/block/
	// serve build their own motion into ContactR/L (via SwingPhase/ServePhase), so
	// they should NOT be re-lerped from the ready pose (that would start the hand
	// at the hip instead of cocked/up). Other hits ease from ready as usual.
	FVector WantHandR;
	FVector WantHandL;
	if (Self.CurrentHit == EHitType::Hit_Spike || Self.CurrentHit == EHitType::Hit_Block
		|| Self.CurrentHit == EHitType::Hit_Serve)
	{
		WantHandR = ContactR;
		WantHandL = ContactL;
	}
	else
	{
		WantHandR = ReadyR + (ContactR - ReadyR) * Blend;
		WantHandL = ReadyL + (ContactL - ReadyL) * Blend;
	}
	// Pose crouch plus whatever extra the AI asked for this frame (ready stance,
	// split step, dive) — the deepest request wins, capped at full crouch.
	float WantCrouch = Math::Clamp(Crouch * Blend + Self.ExtraCrouch, 0.0f, 1.0f);

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
	float MaxStep = 900.0f * Dt;
	Self.SmHandR = MoveTowardClamped(Self.SmHandR, WantHandR, MaxStep);
	Self.SmHandL = MoveTowardClamped(Self.SmHandL, WantHandL, MaxStep);
	Self.SmPoleR = MoveTowardClamped(Self.SmPoleR, PoleR, MaxStep);
	Self.SmPoleL = MoveTowardClamped(Self.SmPoleL, PoleL, MaxStep);
	float RotAlpha = Math::Clamp(14.0f * Dt, 0.0f, 1.0f);
	Self.SmRotR = Math::LerpShortestPath(Self.SmRotR, PalmR, RotAlpha);
	Self.SmRotL = Math::LerpShortestPath(Self.SmRotL, PalmL, RotAlpha);
	// Asymmetric: sinking is athletic (dives, split steps, landings need it
	// fast); RISING is never urgent — a slow release means any on/off crouch
	// source reads as a held stance, not an up-and-down bob.
	float CrouchDown = 6.0f * Dt;
	float CrouchUp   = 1.5f * Dt;
	Self.SmCrouch = Math::Clamp(WantCrouch, Self.SmCrouch - CrouchUp, Self.SmCrouch + CrouchDown);

	Self.Anim.HandTargetR  = Self.SmHandR;
	Self.Anim.HandTargetL  = Self.SmHandL;
	Self.Anim.ElbowPoleR   = Self.SmPoleR;
	Self.Anim.ElbowPoleL   = Self.SmPoleL;
	Self.Anim.HandRotR     = Self.SmRotR;
	Self.Anim.HandRotL     = Self.SmRotL;
	Self.Anim.CrouchAmount = Self.SmCrouch;
}

// Move From toward To by at most MaxStep (cm) — the sink's speed limiter.
FVector MoveTowardClamped(FVector From, FVector To, float MaxStep)
{
	FVector D = To - From;
	float L = D.Size();
	if (L <= MaxStep || L < 0.001f) return To;
	return From + D * (MaxStep / L);
}
