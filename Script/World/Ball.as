// Beach volleyball ball - Euler physics, procedural sphere mesh, collision

class ABall : AActor
{
	UPROPERTY(DefaultComponent, RootComponent)
	UProceduralMeshComponent MeshComp;

	// Physics state (BallVel avoids clash with APawn::GetVelocity if ever reparented)
	FVector BallVel = FVector(0, 0, 0);
	FVector Position = FVector(0, 0, 300);

	const float Gravity = -980.0f;       // cm/s²
	const float BallRadius = 10.66f;     // Mikasa VLS300 / FIVB: 66-68cm circumference (~67cm -> d 21.3cm)
	const float Restitution = 0.75f;     // bounce coefficient
	const float AirDrag = 0.02f;         // drag per second (see StepPhysics scaling)
	const float FloorZ = 5.0f;           // floor collision height

	// Net geometry (set by Court)
	float NetX = 0.0f;
	float NetTopZ = 243.0f;              // regulation net height (243cm)
	float NetHalfThickness = 2.5f;

	bool bInPlay = false;

	// Brief lockout after a player contact so one touch doesn't register twice
	// while the ball is still overlapping the player.
	float PlayerHitCooldown = 0.0f;

	// References (set by GameMode)
	UPROPERTY()
	ASandFX Sand;
	UPROPERTY()
	ACourt Court;
	UPROPERTY()
	ABeachVolleyballGameMode GM;

	UFUNCTION(BlueprintCallable)
	void Launch(FVector Origin, FVector InitVel)
	{
		Position = Origin;
		BallVel = InitVel;
		SetActorLocation(Position);
		bInPlay = true;
	}

	UFUNCTION(BlueprintCallable)
	void HitBall(FVector ImpulseDir, float Speed)
	{
		BallVel = ImpulseDir.GetSafeNormal() * Speed;
	}

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		BuildSphereMesh();
		Log("BALLSHADOW CastShadow=" + MeshComp.CastShadow + " Mobility=" + int(MeshComp.Mobility));

		// THE BALL IS A BALL NOW, NOT A LIGHT BULB.
		//
		// It used to be painted HDR yellow (2.4, 2.3, 0.25) with a 1500-intensity
		// point light inside it, so that it read as self-lit and bloomed. Four
		// problems with that, and they compound:
		//   - An albedo above 1.0 is not a colour any surface has. It reflects more
		//     light than falls on it.
		//   - It guaranteed the ball clipped to a flat yellow blob with no shading
		//     gradient across it — which is why its rotation was invisible even
		//     though UpdateSpin has been computing a correct spin all along.
		//   - The point light sat INSIDE the sphere, so it lit nothing on the ball
		//     and instead threw a fake yellow pool onto the sand that Lumen then
		//     bounced around the court.
		//   - It fought the tonemapper: the one object in frame that ignored it.
		//
		// M_Ball paints real panels instead. Asymmetric panel colour is precisely the
		// cue the eye uses to see rotation, so the spin becomes visible by being
		// lit rather than by being bright. If the ball is ever hard to follow in
		// play, the fix is a motion trail and a grounded contact shadow — not a
		// light bulb.
		if (ApplyAuthoredMaterial("/Game/Materials/M_Ball.M_Ball") == nullptr)
		{
			UMaterialInterface BallMat = Cast<UMaterialInterface>(LoadObject(nullptr,
				"/Engine/BasicShapes/BasicShapeMaterial.BasicShapeMaterial"));
			if (BallMat != nullptr)
			{
				UMaterialInstanceDynamic MID = MeshComp.CreateDynamicMaterialInstance(0, BallMat);
				if (MID != nullptr)
					MID.SetVectorParameterValue(n"Color", FLinearColor(0.72f, 0.64f, 0.16f, 1.0f));
			}
		}
	}

	UFUNCTION(BlueprintOverride)
	void Tick(float DeltaTime)
	{
		if (!bInPlay)
			return;
		// Substep: a hitchy frame (HighResShot writes, shader compiles) can be
		// 0.3-0.5s — one Euler step that long tunnels the ball through floors,
		// nets and contact windows. Cap each physics step at 20ms.
		float Remaining = DeltaTime;
		while (Remaining > 0.0f)
		{
			float Step = Math::Min(Remaining, 0.02f);
			StepPhysics(Step);
			Remaining -= Step;
		}
		SetActorLocation(Position);
		UpdateSpin(DeltaTime);
	}

	// Roll the ball in its travel direction so the spin is visible. A ball moving
	// forward spins about the horizontal axis perpendicular to its velocity, at
	// angular speed v / radius. Purely visual (markings on the ball reveal it).
	// Uses AddActorLocalRotation each frame so spin accumulates without quaternion
	// math: pitch is "rolling forward" in the actor's local frame, and the actor's
	// yaw is aligned to the travel direction so the roll axis stays correct.
	private void UpdateSpin(float Dt)
	{
		FVector Flat = FVector(BallVel.X, BallVel.Y, 0);
		float FlatSpeed = Flat.Size();
		if (FlatSpeed < 5.0f) return;

		// Point the ball's local +X along travel (flat), then roll about local Y
		// (pitch) to make the surface move in the travel direction.
		float Yaw = Flat.Rotation().Yaw;
		float DegPerSec = (BallVel.Size() / (2.0f * PI * BallRadius)) * 360.0f;
		SpinAngle += DegPerSec * Dt;
		if (SpinAngle > 360.0f) SpinAngle -= 360.0f;

		SetActorRotation(FRotator(SpinAngle, Yaw, 0.0f));
	}

	private float SpinAngle = 0.0f;

	UFUNCTION()
	void OnRestartTimer()
	{
		if (GM != nullptr) GM.ResetMatch();
	}

	void StartRestartCountdown(float Delay)
	{
		System::SetTimer(this, n"OnRestartTimer", Delay, bLooping = false);
	}

	private void StepPhysics(float Dt)
	{
		if (PlayerHitCooldown > 0.0f)
			PlayerHitCooldown -= Dt;

		// Apply gravity
		BallVel.Z += Gravity * Dt;

		// Air drag — AirDrag is a per-second fraction, scaled by Dt so it's
		// frame-rate independent. (It used to be applied per frame, ~0.21/s at
		// 60fps, which braked serves so hard they fell short of the net.)
		float Speed = BallVel.Size();
		if (Speed > 0.1f)
			BallVel -= BallVel.GetSafeNormal() * Speed * AirDrag * Dt;

		// Integrate position (remember where we were for the net-plane test —
		// reconstructing it from velocity with a fixed 0.016 step missed real
		// crossings whenever the frame time differed, leaving bServePhase stuck
		// and misattributing rally endings as serve faults).
		float PrevX = Position.X;
		Position += BallVel * Dt;

		// Player body/arm collision — ball physically bounces off players
		CheckPlayerCollision();

		// Floor collision
		if (Position.Z - BallRadius <= FloorZ)
		{
			FVector ImpactVel = BallVel;
			float vDown = Math::Max(0.0f, -BallVel.Z);

			Position.Z = FloorZ + BallRadius;
			BallVel.Z = -BallVel.Z * Restitution;
			BallVel.X *= 0.85f;
			BallVel.Y *= 0.85f;

			if (vDown > 60.0f)
			{
				float Strength = Math::Clamp(vDown / 500.0f, 0.2f, 3.0f);
				FVector Ground = FVector(Position.X, Position.Y, 0.0f);
				if (Sand != nullptr)
					Sand.Burst(Ground, ImpactVel, Strength);
				if (Court != nullptr)
					Court.DeformSand(Ground, 28.0f + Strength * 22.0f, 5.0f + Strength * 9.0f);
			}

			if (GM != nullptr)
				GM.OnBallHitFloor(Position);
		}

		CheckNetCollision(PrevX);
	}

	// Bounce the ball off any player whose arm region it overlaps. The player
	// decides the outgoing velocity (hit type, aim, arc) in OnBallContact.
	private void CheckPlayerCollision()
	{
		if (PlayerHitCooldown > 0.0f) return;

		TArray<AActor> Players;
		GetAllActorsOfClass(AVolleyballPlayer, Players);

		for (AActor A : Players)
		{
			AVolleyballPlayer P = Cast<AVolleyballPlayer>(A);
			if (P == nullptr) continue;

			// A player who just touched the ball is transparent until someone
			// else touches it — enforces "no two contacts in a row".
			if (!P.CanContactBall())
				continue;

			// Ball only bounces off hands/forearms now.
			FVector Center;
			if (!P.GetArmContact(Position, BallRadius, Center))
				continue;

			// Contact: let the player compute the bounce from real physics.
			FVector NewVel = P.OnBallContact(Position, BallVel, Center);
			if (NewVel.SizeSquared() > 1.0f)
				BallVel = NewVel;

			// Push the ball just outside the limb so it doesn't stick.
			float Reach = 18.0f + BallRadius;
			FVector Out = (Position - Center).GetSafeNormal();
			if (Out.SizeSquared() < 0.01f) Out = FVector(0, 0, 1);
			Position = Center + Out * (Reach + 1.0f);

			PlayerHitCooldown = 0.25f;
			break;  // only one contact per frame
		}
	}

	private void CheckNetCollision(float PrevX)
	{
		if ((PrevX < NetX) != (Position.X < NetX))
		{
			if (Position.Z < NetTopZ + BallRadius)
			{
				// Hit the net.
				Log("NETHIT z=" + int(Position.Z) + " netTop=" + int(NetTopZ + BallRadius)
					+ " velX=" + int(BallVel.X) + " velZ=" + int(BallVel.Z));
				BallVel.X = -BallVel.X * 0.3f;
				Position.X = (Position.X < NetX)
					? NetX - NetHalfThickness - BallRadius
					: NetX + NetHalfThickness + BallRadius;

				if (GM != nullptr)
					GM.OnBallHitNet();
			}
			else
			{
				// Cleared the net cleanly — tell the GM (a serve is now good).
				if (GM != nullptr)
					GM.OnBallCrossedNet();
			}
		}
	}

	private UMaterialInstanceDynamic ApplyAuthoredMaterial(FString Path)
	{
		UMaterialInterface Base = Cast<UMaterialInterface>(LoadObject(nullptr, Path));
		if (Base == nullptr)
		{
			Log("MATERIAL missing: " + Path + " — falling back to flat colour");
			return nullptr;
		}
		return MeshComp.CreateDynamicMaterialInstance(0, Base);
	}

	private void BuildSphereMesh()
	{
		TArray<FVector> Verts;
		TArray<int32> Tris;
		TArray<FVector> Normals;
		TArray<FVector2D> UVs;
		TArray<FLinearColor> Colors;
		TArray<FVector2D> NoUV;
		TArray<FProcMeshTangent> Tangents;

		// 12x16 gave a silhouette that read as a polygon at any distance, and a
		// shading terminator coarse enough that the unlit half looked like a hole in
		// the ball. ~3k triangles is free for a single object the camera follows in
		// every frame of the game.
		int Stacks = 32;
		int Slices = 48;
		float R = BallRadius;

		for (int i = 0; i <= Stacks; i++)
		{
			float Phi = PI * i / Stacks;
			for (int j = 0; j <= Slices; j++)
			{
				float Theta = 2.0f * PI * j / Slices;
				FVector N = FVector(
					Math::Sin(Phi) * Math::Cos(Theta),
					Math::Sin(Phi) * Math::Sin(Theta),
					Math::Cos(Phi)
				);
				Verts.Add(N * R);
				Normals.Add(N);
				UVs.Add(FVector2D(float(j) / Slices, float(i) / Stacks));
				Colors.Add(FLinearColor(1, 1, 1, 1));
				// TANGENTS ARE NOT OPTIONAL HERE. This array was declared and never
				// filled, which means a tangent-space normal map could not work on the
				// ball at all. The sand gets away with a world-space normal because it
				// never moves; a ball that spins does not. For a UV sphere the tangent
				// along increasing Theta is simply (-sin Theta, cos Theta, 0).
				FProcMeshTangent Tan;
				Tan.TangentX = FVector(-Math::Sin(Theta), Math::Cos(Theta), 0.0f);
				Tan.bFlipTangentY = false;
				Tangents.Add(Tan);
			}
		}

		for (int i = 0; i < Stacks; i++)
		{
			for (int j = 0; j < Slices; j++)
			{
				int A = i * (Slices + 1) + j;
				int B = A + 1;
				int C = A + Slices + 1;
				int D = C + 1;
				// WINDING. This was inverted for the entire life of this sphere, and
				// it is the reason the ball has never once been lit correctly: with the
				// faces pointing inward, backface culling threw away the near hemisphere
				// and what you actually saw was the INSIDE of the far one — lit by
				// normals pointing away from you. The ball measured 55,50,41 against
				// sand at 142,125,97 that it sits 20cm above, with a pure-black lower
				// half, because the only light reaching it was the sky's upper
				// hemisphere. Flipping these six indices takes it to 111,106,84.
				//
				// It hid for so long because the HDR albedo (2.4,2.3,0.25) and the
				// 1500-intensity point light inside the ball were bright enough to show
				// through anyway. Removing those did not break the ball; it revealed
				// this. Ruled out in order, each on the locked reference series: the
				// material (M_Sand on the ball was equally black), tangents,
				// tessellation, component mobility, self-shadowing, ray-traced shadows,
				// virtual shadow maps, and any occluder (identical 6m in the air).
				Tris.Add(A); Tris.Add(B); Tris.Add(C);
				Tris.Add(B); Tris.Add(D); Tris.Add(C);
			}
		}

		MeshComp.CreateMeshSection_LinearColor(0, Verts, Tris, Normals, UVs,
			NoUV, NoUV, NoUV, Colors, Tangents, true);
	}

	// Where this flight reaches the sand.
	//
	// INTERPOLATES the crossing between the two bracketing samples instead of
	// returning the first sample past the floor. That single line matters more
	// than it looks: with a 50ms step the raw sample overshoots by up to one
	// step of horizontal travel, and as real time advances the number of
	// remaining steps drops by one every 50ms — so the answer JUMPED by a
	// step-worth of travel, 20 times a second. At 400-900 cm/s of ball speed
	// that is a 20-45cm sawtooth at 20Hz, feeding AmIHitter, the receive
	// half-claim and every goal derived from them, and it was comparable in size
	// to the +/-60cm margin those decisions compare against. The AI was
	// re-deciding on quantisation noise.
	FVector PredictLanding(float MaxTime = 3.0f) const
	{
		FVector PPos = Position;
		FVector PVel = BallVel;
		float Dt = 0.05f;
		float T = 0;
		float Floor = FloorZ + BallRadius;

		while (T < MaxTime)
		{
			FVector Prev = PPos;
			PVel.Z += Gravity * Dt;
			PPos += PVel * Dt;
			T += Dt;
			if (PPos.Z <= Floor)
			{
				// Fraction of this step at which the floor is actually crossed.
				float Span = Prev.Z - PPos.Z;
				float Frac = (Span > 0.0001f)
					? Math::Clamp((Prev.Z - Floor) / Span, 0.0f, 1.0f) : 1.0f;
				return Prev + (PPos - Prev) * Frac;
			}
		}
		return PPos;
	}
}
