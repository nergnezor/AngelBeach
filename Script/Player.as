// Base player pawn - movement, jump, hit actions

class AVolleyballPlayer : APawn
{
	UPROPERTY()
	UCapsuleComponent Capsule;

	// Procedural stylised body (built/animated each frame in RebuildBody)
	UPROPERTY()
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

	// Sand FX references (set by GameMode)
	UPROPERTY()
	ASandFX Sand;
	UPROPERTY()
	ACourt Court;
	private float StepTimer = 0.0f;

	// --- Stylised body animation state ---
	private float WalkPhase = 0.0f;
	private float ReachTimer = 0.0f;       // >0 while arms reach for the ball
	private FVector ReachDir = FVector(0, 0, 1);
	private bool bBodyBuilt = false;

	// Court bounds (set by GameMode)
	float CourtMinX = -450.0f;
	float CourtMaxX = -5.0f;     // net side boundary
	float CourtMinY = -450.0f;
	float CourtMaxY = 450.0f;

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		FVector Loc = GetActorLocation();
		FloorZ = Loc.Z;
	}

	UFUNCTION(BlueprintOverride)
	void Tick(float DeltaTime)
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
				// Faster strides at higher speed.
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
			WalkPhase *= (1.0f - Math::Clamp(6.0f * DeltaTime, 0.0f, 1.0f)); // settle

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

		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(Gameplay::GetGameState());
		if (GS != nullptr)
		{
			bool bValid = GS.RegisterTouch(TeamSide);
			if (!bValid)
			{
				ABeachVolleyballGameMode GM = Cast<ABeachVolleyballGameMode>(Gameplay::GetGameMode());
				if (GM != nullptr)
					GM.OnTouchViolation(TeamSide);
			}
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
		TArray<FProcMeshTangent> Tan;

		FLinearColor Team = TeamColor();
		FLinearColor Skin = FLinearColor(0.95f, 0.78f, 0.60f, 1);

		// Local layout (origin = actor pivot, ground at z = -PlayerHeight).
		float hipZ = -5.0f;
		float neckZ = 40.0f;
		float shoulderZ = 32.0f;
		float shoulderY = 15.0f;
		float hipY = 8.0f;
		float footZ = -PlayerHeight;

		// Subtle bob while walking.
		float bob = Math::Sin(WalkPhase * 2.0f) * 3.0f;

		// Torso + head
		AddTube(V, T, N, UV, C, FVector(0, 0, hipZ + bob), FVector(0, 0, neckZ + bob),
			13.0f, 10.0f, 6, Team);
		AddSphere(V, T, N, UV, C, FVector(0, 0, neckZ + 14.0f + bob), 12.0f, 6, 8, Skin);

		// --- Arms ---
		FVector shL = FVector(0,  shoulderY, shoulderZ + bob);
		FVector shR = FVector(0, -shoulderY, shoulderZ + bob);
		FVector handL;
		FVector handR;

		if (ReachTimer > 0.0f)
		{
			handL = shL + ReachDir * 48.0f + FVector(0,  8, 0);
			handR = shR + ReachDir * 48.0f + FVector(0, -8, 0);
		}
		else if (!bIsGrounded)
		{
			handL = shL + FVector(0,  6, 44.0f);   // arms up in the air
			handR = shR + FVector(0, -6, 44.0f);
		}
		else
		{
			float arm = Math::Sin(WalkPhase) * 10.0f;   // gentle swing
			handL = shL + FVector( arm,  10, -34.0f);
			handR = shR + FVector(-arm, -10, -34.0f);
		}

		AddTube(V, T, N, UV, C, shL, handL, 4.5f, 3.0f, 5, Team);
		AddTube(V, T, N, UV, C, shR, handR, 4.5f, 3.0f, 5, Team);

		// --- Legs ---
		FVector hipL = FVector(0,  hipY, hipZ + bob);
		FVector hipR = FVector(0, -hipY, hipZ + bob);
		FVector footL;
		FVector footR;

		if (!bIsGrounded)
		{
			footL = FVector(-8,  hipY + 2, hipZ - 42.0f);  // tucked
			footR = FVector(-8, -hipY - 2, hipZ - 42.0f);
		}
		else
		{
			float swing = Math::Sin(WalkPhase) * 16.0f;
			footL = FVector( swing,  hipY, footZ);
			footR = FVector(-swing, -hipY, footZ);
		}

		AddTube(V, T, N, UV, C, hipL, footL, 6.0f, 4.5f, 5, Team);
		AddTube(V, T, N, UV, C, hipR, footR, 6.0f, 4.5f, 5, Team);

		Body.CreateMeshSection_LinearColor(0, V, T, N, UV,
			TArray<FVector2D>(), TArray<FVector2D>(), TArray<FVector2D>(),
			C, Tan, false, false);
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
