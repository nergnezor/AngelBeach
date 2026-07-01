// Beach volleyball ball - Euler physics, procedural sphere mesh, collision

class ABall : AActor
{
	UPROPERTY()
	UProceduralMeshComponent MeshComp;

	// Physics state
	FVector Velocity = FVector(0, 0, 0);
	FVector Position = FVector(0, 0, 300);

	const float Gravity = -980.0f;       // cm/s²
	const float BallRadius = 10.5f;      // regulation ~21cm diameter
	const float Restitution = 0.75f;     // bounce coefficient
	const float AirDrag = 0.0035f;       // per-frame drag
	const float FloorZ = 5.0f;           // floor collision height

	// Net geometry (set by Court)
	float NetX = 0.0f;
	float NetTopZ = 243.0f;              // regulation net height (243cm)
	float NetHalfThickness = 2.5f;

	bool bInPlay = false;

	// FX references (set by GameMode)
	UPROPERTY()
	ASandFX Sand;
	UPROPERTY()
	ACourt Court;

	UFUNCTION(BlueprintCallable)
	void Launch(FVector Origin, FVector InitVelocity)
	{
		Position = Origin;
		Velocity = InitVelocity;
		SetActorLocation(Position);
		bInPlay = true;
	}

	UFUNCTION(BlueprintCallable)
	void HitBall(FVector ImpulseDir, float Speed)
	{
		Velocity = ImpulseDir.GetSafeNormal() * Speed;
	}

	void BeginPlay() override
	{
		BuildSphereMesh();
	}

	void Tick(float DeltaTime) override
	{
		if (!bInPlay) return;

		StepPhysics(DeltaTime);
		SetActorLocation(Position);
	}

	private void StepPhysics(float Dt)
	{
		// Apply gravity
		Velocity.Z += Gravity * Dt;

		// Air drag
		float Speed = Velocity.Size();
		if (Speed > 0.1f)
			Velocity -= Velocity.GetSafeNormal() * Speed * AirDrag;

		// Integrate position
		Position += Velocity * Dt;

		// Floor collision
		if (Position.Z - BallRadius <= FloorZ)
		{
			// Capture impact velocity before the bounce reverses it.
			FVector ImpactVel = Velocity;
			float vDown = Math::Max(0.0f, -Velocity.Z);

			Position.Z = FloorZ + BallRadius;
			Velocity.Z = -Velocity.Z * Restitution;
			Velocity.X *= 0.85f;
			Velocity.Y *= 0.85f;

			// Spray sand upward and dent a crater (only on real impacts).
			if (vDown > 60.0f)
			{
				float Strength = Math::Clamp(vDown / 500.0f, 0.2f, 3.0f);
				FVector Ground = FVector(Position.X, Position.Y, 0.0f);
				if (Sand != nullptr)
					Sand.Burst(Ground, ImpactVel, Strength);
				if (Court != nullptr)
					Court.DeformSand(Ground, 28.0f + Strength * 22.0f, 5.0f + Strength * 9.0f);
			}

			// Notify game mode of floor hit
			ABeachVolleyballGameMode GM = Cast<ABeachVolleyballGameMode>(Gameplay::GetGameMode());
			if (GM != nullptr)
				GM.OnBallHitFloor(Position);
		}

		// Net collision (simple AABB)
		CheckNetCollision();
	}

	private void CheckNetCollision()
	{
		// Net runs along Y axis at X=0
		float PrevX = Position.X - Velocity.X * 0.016f;
		if ((PrevX < NetX) != (Position.X < NetX))
		{
			// Ball crossed net line - check height
			if (Position.Z < NetTopZ + BallRadius)
			{
				// Hit the net - reverse X velocity
				Velocity.X = -Velocity.X * 0.3f;
				Position.X = (Position.X < NetX)
					? NetX - NetHalfThickness - BallRadius
					: NetX + NetHalfThickness + BallRadius;

				ABeachVolleyballGameMode GM = Cast<ABeachVolleyballGameMode>(Gameplay::GetGameMode());
				if (GM != nullptr)
					GM.OnBallHitNet();
			}
		}
	}

	// Generate icosphere-style procedural sphere
	private void BuildSphereMesh()
	{
		TArray<FVector> Verts;
		TArray<int32> Tris;
		TArray<FVector> Normals;
		TArray<FVector2D> UVs;
		TArray<FProcMeshTangent> Tangents;

		int Stacks = 12;
		int Slices = 16;
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
				Tris.Add(A); Tris.Add(C); Tris.Add(B);
				Tris.Add(B); Tris.Add(C); Tris.Add(D);
			}
		}

		MeshComp.CreateMeshSection_LinearColor(0, Verts, Tris, Normals, UVs,
			TArray<FVector2D>(), TArray<FVector2D>(), TArray<FVector2D>(),
			TArray<FLinearColor>(), Tangents, true, false);

		// White volleyball material (vertex color)
		TArray<FLinearColor> Colors;
		for (int i = 0; i < Verts.Num(); i++)
			Colors.Add(FLinearColor(1, 1, 1, 1));
		MeshComp.UpdateMeshSection_LinearColor(0, Verts, Normals, UVs,
			TArray<FVector2D>(), TArray<FVector2D>(), TArray<FVector2D>(),
			Colors, Tangents, false);
	}

	// Return predicted landing position via forward integration
	FVector PredictLanding(float MaxTime = 3.0f) const
	{
		FVector PPos = Position;
		FVector PVel = Velocity;
		float Dt = 0.05f;
		float T = 0;

		while (T < MaxTime)
		{
			PVel.Z += Gravity * Dt;
			PPos += PVel * Dt;
			T += Dt;
			if (PPos.Z <= FloorZ + BallRadius)
				return PPos;
		}
		return PPos;
	}
}
