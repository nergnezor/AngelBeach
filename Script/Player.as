// Base player pawn - movement, jump, hit actions

class AVolleyballPlayer : APawn
{
	UPROPERTY()
	UCapsuleComponent Capsule;

	UPROPERTY()
	UStaticMeshComponent BodyMesh;

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

	void BeginPlay() override
	{
		Super::BeginPlay();
		FVector Loc = GetActorLocation();
		FloorZ = Loc.Z;
	}

	void Tick(float DeltaTime) override
	{
		Super::Tick(DeltaTime);

		// Gravity
		if (!bIsGrounded)
			PlayerVelocity.Z += Gravity * DeltaTime;

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
			if (!bValid)
			{
				ABeachVolleyballGameMode GM = Cast<ABeachVolleyballGameMode>(GetWorld().GetAuthGameMode());
				if (GM != nullptr)
					GM.OnTouchViolation(TeamSide);
			}
		}
	}
}
