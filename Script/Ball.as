// Beach volleyball ball - Euler physics, procedural sphere mesh, collision

class ABall : AActor
{
	UPROPERTY(DefaultComponent, RootComponent)
	UProceduralMeshComponent MeshComp;

	// Physics state (BallVel avoids clash with APawn::GetVelocity if ever reparented)
	FVector BallVel = FVector(0, 0, 0);
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
	}

	UFUNCTION(BlueprintOverride)
	void Tick(float DeltaTime)
	{
		if (!bInPlay)
			return;
		StepPhysics(DeltaTime);
		SetActorLocation(Position);
	}

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
		// Apply gravity
		BallVel.Z += Gravity * Dt;

		// Air drag
		float Speed = BallVel.Size();
		if (Speed > 0.1f)
			BallVel -= BallVel.GetSafeNormal() * Speed * AirDrag;

		// Integrate position
		Position += BallVel * Dt;

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

		CheckNetCollision();
	}

	private void CheckNetCollision()
	{
		float PrevX = Position.X - BallVel.X * 0.016f;
		if ((PrevX < NetX) != (Position.X < NetX))
		{
			if (Position.Z < NetTopZ + BallRadius)
			{
				BallVel.X = -BallVel.X * 0.3f;
				Position.X = (Position.X < NetX)
					? NetX - NetHalfThickness - BallRadius
					: NetX + NetHalfThickness + BallRadius;

				if (GM != nullptr)
					GM.OnBallHitNet();
			}
		}
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
				Colors.Add(FLinearColor(1, 1, 1, 1));
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
			NoUV, NoUV, NoUV, Colors, Tangents, true);
	}

	FVector PredictLanding(float MaxTime = 3.0f) const
	{
		FVector PPos = Position;
		FVector PVel = BallVel;
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
