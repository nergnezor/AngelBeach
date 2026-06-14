// Base player pawn - movement, jump, hit actions, procedural stylised body

class AVolleyballPlayer : APawn
{
	UPROPERTY(DefaultComponent, RootComponent)
	UCapsuleComponent Capsule;

	// Procedural stylised body (built/animated each frame in RebuildBody)
	UPROPERTY(DefaultComponent, Attach = Capsule)
	UProceduralMeshComponent Body;

	// Movement params
	float MoveSpeed = 450.0f;
	float JumpVelocity = 600.0f;
	float Gravity = -980.0f;

	FVector PlayerVelocity = FVector::ZeroVector;
	bool bIsGrounded = true;
	float FloorZ = 0.0f;
	float PlayerHeight = 90.0f;  // capsule half-height

	ETeam TeamSide = ETeam::Team_A;
	bool bCanHit = true;
	float HitCooldown = 0.4f;
	float HitTimer = 0.0f;

	// Court bounds (set by GameMode)
	float CourtMinX = -450.0f;
	float CourtMaxX = -5.0f;     // net side boundary
	float CourtMinY = -450.0f;
	float CourtMaxY = 450.0f;

	// References (set by GameMode)
	UPROPERTY()
	ASandFX Sand;
	UPROPERTY()
	ACourt Court;
	UPROPERTY()
	ABeachVolleyballGameMode GM;
	private float StepTimer = 0.0f;

	// --- Stylised body animation state ---
	private float WalkPhase = 0.0f;
	private float ReachTimer = 0.0f;       // >0 while arms reach for the ball
	private FVector ReachDir = FVector(0, 0, 1);

	// Base setup, called by subclasses from their BeginPlay.
	void InitPlayer()
	{
		FloorZ = 0.0f;
	}

	// Base per-frame update, called by subclasses from their Tick.
	void UpdatePlayer(float DeltaTime)
	{
		// Gravity
		if (!bIsGrounded)
			PlayerVelocity.Z += Gravity * DeltaTime;

		bool bWasGrounded = bIsGrounded;
		float FallSpeed = -PlayerVelocity.Z;   // >0 while descending

		FVector NewLoc = GetActorLocation() + PlayerVelocity * DeltaTime;

		// Floor clamp
		if (NewLoc.Z <= FloorZ + PlayerHeight)
		{
			NewLoc.Z = FloorZ + PlayerHeight;
			PlayerVelocity.Z = 0;
			bIsGrounded = true;
		}

		// Court bounds clamp
		NewLoc.X = Math::Clamp(NewLoc.X, CourtMinX, CourtMaxX);
		NewLoc.Y = Math::Clamp(NewLoc.Y, CourtMinY, CourtMaxY);

		SetActorLocation(NewLoc);

		// --- Sand FX: landing burst + running footsteps ---
		FVector Feet = FVector(NewLoc.X, NewLoc.Y, 0.0f);

		if (bIsGrounded && !bWasGrounded && FallSpeed > 120.0f)
		{
			float Strength = Math::Clamp(FallSpeed / 600.0f, 0.3f, 1.6f);
			if (Sand != nullptr) Sand.Footstep(Feet, Strength * 1.4f);
			if (Court != nullptr) Court.DeformSand(Feet, 24.0f, 4.0f + Strength * 6.0f);
		}

		if (bIsGrounded)
		{
			float HSpeed = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0).Size();
			if (HSpeed > 80.0f)
			{
				StepTimer += DeltaTime;
				float Interval = Math::Clamp(120.0f / HSpeed, 0.18f, 0.5f);
				if (StepTimer >= Interval)
				{
					StepTimer = 0.0f;
					if (Sand != nullptr) Sand.Footstep(Feet, 0.5f);
					if (Court != nullptr) Court.DeformSand(Feet, 16.0f, 3.0f);
				}
			}
			else
			{
				StepTimer = 0.0f;
			}
		}

		// Hit cooldown
		if (!bCanHit)
		{
			HitTimer += DeltaTime;
			if (HitTimer >= HitCooldown)
			{
				bCanHit = true;
				HitTimer = 0;
			}
		}

		// --- Body animation ---
		float HSpeed2 = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0).Size();
		if (bIsGrounded && HSpeed2 > 30.0f)
			WalkPhase += DeltaTime * (HSpeed2 / 60.0f);
		else
			WalkPhase *= (1.0f - Math::Clamp(6.0f * DeltaTime, 0.0f, 1.0f));

		if (ReachTimer > 0.0f)
			ReachTimer -= DeltaTime;

		RebuildBody();
	}

	// Called by the hit actions so the arms reach toward the ball.
	protected void TriggerReach(FVector WorldDir)
	{
		ReachDir = WorldDir.GetSafeNormal();
		ReachTimer = 0.35f;
	}

	UFUNCTION(BlueprintCallable)
	void MovePlayer(FVector2D Input)
	{
		PlayerVelocity.X = Input.X * MoveSpeed;
		PlayerVelocity.Y = Input.Y * MoveSpeed;
	}

	UFUNCTION(BlueprintCallable)
	void Jump()
	{
		if (bIsGrounded)
		{
			PlayerVelocity.Z = JumpVelocity;
			bIsGrounded = false;
		}
	}

	// Pass: gentle upward hit toward own team area
	UFUNCTION(BlueprintCallable)
	void TryPass(ABall Ball)
	{
		if (Ball == nullptr || !bCanHit) return;
		if (!IsNearBall(Ball)) return;

		FVector Dir = FVector(0.3f, 0, 1.0f).GetSafeNormal();
		Ball.HitBall(Dir, 500.0f);
		TriggerReach(FVector(0, 0, 1));
		RegisterHit(Ball);
	}

	// Set: angled hit toward net
	UFUNCTION(BlueprintCallable)
	void TrySet(ABall Ball)
	{
		if (Ball == nullptr || !bCanHit) return;
		if (!IsNearBall(Ball)) return;

		float XDir = (TeamSide == ETeam::Team_A) ? 1.0f : -1.0f;
		FVector Dir = FVector(XDir * 0.7f, 0, 0.7f).GetSafeNormal();
		Ball.HitBall(Dir, 600.0f);
		TriggerReach(FVector(XDir * 0.5f, 0, 1.0f));
		RegisterHit(Ball);
	}

	// Spike: powerful downward hit over net
	UFUNCTION(BlueprintCallable)
	void TrySpike(ABall Ball)
	{
		if (Ball == nullptr || !bCanHit) return;
		if (!IsNearBall(Ball)) return;

		float XDir = (TeamSide == ETeam::Team_A) ? 1.0f : -1.0f;
		FVector ToNet = FVector(XDir, 0, -0.4f).GetSafeNormal();
		Ball.HitBall(ToNet, 1200.0f);
		TriggerReach(FVector(XDir * 0.4f, 0, 1.0f));  // arm up to strike
		RegisterHit(Ball);
	}

	protected bool IsNearBall(ABall Ball) const
	{
		FVector MyLoc = GetActorLocation();
		FVector BallLoc = Ball.GetActorLocation();
		float Dist = (MyLoc - BallLoc).Size();
		return Dist < 120.0f;
	}

	private void RegisterHit(ABall Ball)
	{
		bCanHit = false;
		HitTimer = 0;

		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS != nullptr)
		{
			bool bValid = GS.RegisterTouch(TeamSide);
			if (!bValid && GM != nullptr)
				GM.OnTouchViolation(TeamSide);
		}
	}

	// ============================ Stylised body ============================

	private FLinearColor TeamColor() const
	{
		return (TeamSide == ETeam::Team_A)
			? FLinearColor(0.15f, 0.35f, 0.85f, 1)   // blue
			: FLinearColor(0.85f, 0.20f, 0.20f, 1);  // red
	}

	private FVector Cross(FVector A, FVector B) const
	{
		return FVector(A.Y*B.Z - A.Z*B.Y, A.Z*B.X - A.X*B.Z, A.X*B.Y - A.Y*B.X);
	}

	// Rebuild the figure each frame so it poses with movement, jump and hits.
	private void RebuildBody()
	{
		if (Body == nullptr) return;

		TArray<FVector> V;
		TArray<int32> T;
		TArray<FVector> N;
		TArray<FVector2D> UV;
		TArray<FLinearColor> C;

		FLinearColor Team = TeamColor();
		FLinearColor Skin  = FLinearColor(0.95f, 0.78f, 0.60f, 1);
		FLinearColor Short = FLinearColor(Team.R * 0.6f, Team.G * 0.6f, Team.B * 0.6f, 1); // darker shorts

		float Bob      = Math::Sin(WalkPhase * 2.0f) * 2.5f;
		float Walk     = WalkPhase;

		// Skeleton landmarks (local space, origin = feet level + PlayerHeight)
		float PelvisZ  = -8.0f  + Bob;
		float WaistZ   =  8.0f  + Bob;
		float ChestZ   = 28.0f  + Bob;
		float NeckZ    = 44.0f  + Bob;
		float HeadZ    = NeckZ  + 14.0f;
		float ShoulderY = 16.0f;
		float ShoulderZ = ChestZ - 4.0f;
		float HipY     =  9.0f;
		float KneeY    =  7.0f;
		float ThighLen = 38.0f;
		float ShinLen  = 38.0f;
		float UpperArmLen = 24.0f;
		float ForeArmLen  = 22.0f;

		// --- Torso ---
		AddTube(V, T, N, UV, C,
			FVector(0, 0, PelvisZ), FVector(0, 0, WaistZ), 11.0f, 10.0f, 8, Short);
		AddTube(V, T, N, UV, C,
			FVector(0, 0, WaistZ),  FVector(0, 0, NeckZ),  10.0f,  8.0f, 8, Team);

		// Head
		AddSphere(V, T, N, UV, C, FVector(0, 0, HeadZ), 11.0f, 7, 10, Skin);

		// --- Arms ---
		FVector ShL = FVector(0,  ShoulderY, ShoulderZ);
		FVector ShR = FVector(0, -ShoulderY, ShoulderZ);
		FVector ElbowL, ElbowR, HandL, HandR;

		if (ReachTimer > 0.0f)
		{
			FVector Reach = ReachDir * UpperArmLen;
			ElbowL = ShL + Reach + FVector(0,  3, 0);
			ElbowR = ShR + Reach + FVector(0, -3, 0);
			HandL  = ElbowL + ReachDir * ForeArmLen;
			HandR  = ElbowR + ReachDir * ForeArmLen;
		}
		else if (!bIsGrounded)
		{
			ElbowL = ShL + FVector(0,  4, UpperArmLen * 0.6f);
			ElbowR = ShR + FVector(0, -4, UpperArmLen * 0.6f);
			HandL  = ElbowL + FVector(0,  2, ForeArmLen * 0.8f);
			HandR  = ElbowR + FVector(0, -2, ForeArmLen * 0.8f);
		}
		else
		{
			float Swing = Math::Sin(Walk) * 12.0f;
			ElbowL = ShL + FVector( Swing * 0.4f,  5, -UpperArmLen * 0.7f);
			ElbowR = ShR + FVector(-Swing * 0.4f, -5, -UpperArmLen * 0.7f);
			HandL  = ElbowL + FVector( Swing * 0.6f,  4, -ForeArmLen * 0.9f);
			HandR  = ElbowR + FVector(-Swing * 0.6f, -4, -ForeArmLen * 0.9f);
		}

		AddTube(V, T, N, UV, C, ShL,    ElbowL, 4.5f, 3.5f, 6, Team);
		AddTube(V, T, N, UV, C, ElbowL, HandL,  3.5f, 2.5f, 6, Skin);
		AddTube(V, T, N, UV, C, ShR,    ElbowR, 4.5f, 3.5f, 6, Team);
		AddTube(V, T, N, UV, C, ElbowR, HandR,  3.5f, 2.5f, 6, Skin);

		// --- Legs ---
		FVector HipL = FVector(0,  HipY, PelvisZ);
		FVector HipR = FVector(0, -HipY, PelvisZ);
		FVector KneeL, KneeR, AnkleL, AnkleR;

		if (!bIsGrounded)
		{
			KneeL  = HipL  + FVector(-6,  KneeY, -ThighLen * 0.9f);
			KneeR  = HipR  + FVector(-6, -KneeY, -ThighLen * 0.9f);
			AnkleL = KneeL + FVector( 8,  2, -ShinLen * 0.7f);
			AnkleR = KneeR + FVector( 8, -2, -ShinLen * 0.7f);
		}
		else
		{
			float SwingL =  Math::Sin(Walk) * 18.0f;
			float SwingR = -Math::Sin(Walk) * 18.0f;
			float KneeFwdL = Math::Max(0.0f,  Math::Sin(Walk)) * 8.0f;
			float KneeFwdR = Math::Max(0.0f, -Math::Sin(Walk)) * 8.0f;

			KneeL  = HipL  + FVector(KneeFwdL,  HipY * 0.4f, -ThighLen + SwingL * 0.1f);
			KneeR  = HipR  + FVector(KneeFwdR, -HipY * 0.4f, -ThighLen + SwingR * 0.1f);
			AnkleL = KneeL + FVector(SwingL * 0.5f,  1, -ShinLen);
			AnkleR = KneeR + FVector(SwingR * 0.5f, -1, -ShinLen);

			float FloorLocal = -PlayerHeight + 4.0f;
			AnkleL.Z = Math::Max(AnkleL.Z, FloorLocal);
			AnkleR.Z = Math::Max(AnkleR.Z, FloorLocal);
		}

		AddTube(V, T, N, UV, C, HipL,   KneeL,  6.5f, 5.0f, 7, Short);
		AddTube(V, T, N, UV, C, KneeL,  AnkleL, 5.0f, 3.5f, 7, Skin);
		AddTube(V, T, N, UV, C, HipR,   KneeR,  6.5f, 5.0f, 7, Short);
		AddTube(V, T, N, UV, C, KneeR,  AnkleR, 5.0f, 3.5f, 7, Skin);

		// Feet
		FVector FootDirL = FVector( Math::Sin(Walk) * 0.3f + 0.7f, 0, 0).GetSafeNormal();
		FVector FootDirR = FVector(-Math::Sin(Walk) * 0.3f + 0.7f, 0, 0).GetSafeNormal();
		AddTube(V, T, N, UV, C, AnkleL, AnkleL + FootDirL * 10.0f, 3.5f, 2.0f, 6, Skin);
		AddTube(V, T, N, UV, C, AnkleR, AnkleR + FootDirR * 10.0f, 3.5f, 2.0f, 6, Skin);

		TArray<FVector2D> NoUV;
		TArray<FProcMeshTangent> Tan;
		Body.CreateMeshSection_LinearColor(0, V, T, N, UV, NoUV, NoUV, NoUV, C, Tan, false);
	}

	// Tapered cylinder between two local points.
	private void AddTube(TArray<FVector>& V, TArray<int32>& T, TArray<FVector>& N,
		TArray<FVector2D>& UV, TArray<FLinearColor>& C,
		FVector A, FVector B, float rA, float rB, int Segs, FLinearColor Col)
	{
		FVector axis = B - A;
		float len = axis.Size();
		if (len < 0.01f) return;
		axis = axis / len;

		FVector up = (Math::Abs(axis.Z) > 0.9f) ? FVector(1, 0, 0) : FVector(0, 0, 1);
		FVector u = Cross(up, axis).GetSafeNormal();
		FVector v = Cross(axis, u).GetSafeNormal();

		int base = V.Num();
		for (int i = 0; i < Segs; i++)
		{
			float ang = 2.0f * PI * i / Segs;
			FVector dir = u * Math::Cos(ang) + v * Math::Sin(ang);
			V.Add(A + dir * rA); N.Add(dir); UV.Add(FVector2D(0, 0)); C.Add(Col);
			V.Add(B + dir * rB); N.Add(dir); UV.Add(FVector2D(1, 1)); C.Add(Col);
		}
		for (int i = 0; i < Segs; i++)
		{
			int a = base + i * 2;
			int b = base + ((i + 1) % Segs) * 2;
			T.Add(a);   T.Add(b);   T.Add(b + 1);
			T.Add(a);   T.Add(b + 1); T.Add(a + 1);
		}
	}

	// UV-sphere at a local center.
	private void AddSphere(TArray<FVector>& V, TArray<int32>& T, TArray<FVector>& N,
		TArray<FVector2D>& UV, TArray<FLinearColor>& C,
		FVector Center, float R, int Stacks, int Slices, FLinearColor Col)
	{
		int base = V.Num();
		for (int i = 0; i <= Stacks; i++)
		{
			float phi = PI * i / Stacks;
			for (int j = 0; j <= Slices; j++)
			{
				float theta = 2.0f * PI * j / Slices;
				FVector nrm = FVector(
					Math::Sin(phi) * Math::Cos(theta),
					Math::Sin(phi) * Math::Sin(theta),
					Math::Cos(phi));
				V.Add(Center + nrm * R);
				N.Add(nrm);
				UV.Add(FVector2D(float(j) / Slices, float(i) / Stacks));
				C.Add(Col);
			}
		}
		for (int i = 0; i < Stacks; i++)
		{
			for (int j = 0; j < Slices; j++)
			{
				int a = base + i * (Slices + 1) + j;
				int b = a + 1;
				int c = a + Slices + 1;
				int d = c + 1;
				T.Add(a); T.Add(c); T.Add(b);
				T.Add(b); T.Add(c); T.Add(d);
			}
		}
	}
}
