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
// on AVolleyballPlayer for this mixin).
mixin void UpdateIKTargets(AVolleyballPlayer Self, float Blend)
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

	if (Self.CurrentHit == EHitType::Hit_Bump)
	{
		// Bagger/dig: arms STRAIGHT and flat, hands JOINED under the ball so the
		// forearm platform meets it. Both hands converge on the ball contact,
		// pulled a little low so the platform is beneath the ball.
		FVector Platform = BallContact - Up * 12.0f;
		ContactR = Platform - Right * 6.0f;
		ContactL = Platform + Right * 6.0f;
		// Elbows pulled DOWN and back so the arms lock out straight.
		PoleR = ContactR - Up * 45.0f - Fwd * 25.0f;
		PoleL = ContactL - Up * 45.0f - Fwd * 25.0f;
		// Forearm platform faces up toward the aim arc.
		PalmR = (AimFlat * 0.5f + Up).GetSafeNormal().Rotation();
		PalmL = PalmR;
		Crouch = 0.6f;
	}
	else if (Self.CurrentHit == EHitType::Hit_Set)
	{
		// Fingerpass/set: hands form a CUP under/around the ball above the brow,
		// elbows forward. On contact (Blend->1) the palms push up-forward toward
		// the aim, as if shoving the ball away.
		FVector Cup = BallContact - Up * 6.0f;               // hands just under the ball
		FVector Push = (AimFlat * 0.6f + Up * 0.8f).GetSafeNormal() * 14.0f;
		ContactR = Cup - Right * 11.0f + Push * Blend;
		ContactL = Cup + Right * 11.0f + Push * Blend;
		// Elbows point FORWARD (and slightly out) — the set's signature shape.
		PoleR = ShR + Fwd * 40.0f - Right * 10.0f;
		PoleL = ShL + Fwd * 40.0f + Right * 10.0f;
		PalmR = (AimFlat * 0.5f + Up).GetSafeNormal().Rotation();
		PalmL = PalmR;
		Crouch = 0.2f;
	}
	else if (Self.CurrentHit == EHitType::Hit_Spike)
	{
		// Spike, in two phases driven by Blend (0 = cock, 1 = strike):
		//  - LEFT arm aims at the ball throughout (points/tracks it before the hit).
		//  - RIGHT hand starts cocked just OUTSIDE the right cheek, then swings
		//    forward/up to strike with a near-straight arm ABOVE and slightly in
		//    FRONT of the right shoulder.
		// Left arm: extend toward the ball (clamped to arm reach), tracking it.
		FVector ToBallL = (BallContact - ShL);
		float ReachL = 95.0f;
		if (ToBallL.Size() > ReachL) ToBallL = ToBallL.GetSafeNormal() * ReachL;
		ContactL = ShL + ToBallL;
		PoleL = ShL + ToBallL * 0.4f - Up * 15.0f;   // elbow softly under the aim line
		PalmL = ToBallL.GetSafeNormal().Rotation();

		// Right hand cocked outside the right cheek (head height, out to the right,
		// slightly back), then driving to a strike point above + in front of the
		// right shoulder, reaching toward the ball's height.
		FVector Cheek  = Head + Right * 22.0f + Up * 2.0f - Fwd * 8.0f;   // outside right cheek
		float StrikeUp = Math::Max(35.0f, BallContact.Z - ShR.Z);         // reach up to ball
		FVector Strike = ShR + Up * StrikeUp + Fwd * 22.0f + Right * 6.0f; // above & front of R shoulder
		ContactR = Cheek + (Strike - Cheek) * Blend;
		// Elbow stays high and back early, leading the hand on the swing.
		PoleR = ContactR + Up * 25.0f - Fwd * 30.0f + Right * 10.0f;
		// Palm faces the aim/down as it comes over the top.
		PalmR = (AimFlat * 0.5f + Up * (1.0f - Blend) - Up * 0.3f * Blend).GetSafeNormal().Rotation();
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
	else
	{
		ContactR = ReadyR; ContactL = ReadyL;
		PoleR = ShR - Up * 40.0f; PoleL = ShL - Up * 40.0f;
	}

	// Ease from ready to the contact pose by the gesture weight. The spike/block
	// build their own motion into ContactR/L via Blend, so they should NOT be
	// re-lerped from the ready pose (that would start the hand at the hip instead
	// of cocked/up). Other hits ease from ready as usual.
	if (Self.CurrentHit == EHitType::Hit_Spike || Self.CurrentHit == EHitType::Hit_Block)
	{
		Self.Anim.HandTargetR = ContactR;
		Self.Anim.HandTargetL = ContactL;
	}
	else
	{
		Self.Anim.HandTargetR = ReadyR + (ContactR - ReadyR) * Blend;
		Self.Anim.HandTargetL = ReadyL + (ContactL - ReadyL) * Blend;
	}
	Self.Anim.ElbowPoleR  = PoleR;
	Self.Anim.ElbowPoleL  = PoleL;
	Self.Anim.HandRotR    = PalmR;
	Self.Anim.HandRotL    = PalmL;
	Self.Anim.CrouchAmount = Crouch * Blend;
}
