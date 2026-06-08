// AI player with trajectory prediction and adjustable difficulty

enum EAIState
{
	AI_Idle,
	AI_Positioning,
	AI_Approach,
	AI_Hitting
}

class AAIPlayer : AVolleyballPlayer
{
	UPROPERTY(BlueprintReadWrite)
	float Difficulty = 0.7f;  // 0..1, higher = smarter

	UPROPERTY()
	ABall Ball;

	EAIState AIState = EAIState::AI_Idle;

	float ReactionDelay = 0.0f;
	float ReactionTimer = 0.0f;
	FVector TargetPosition = FVector::ZeroVector;
	bool bHasTarget = false;

	void BeginPlay() override
	{
		Super::BeginPlay();
		TeamSide = ETeam::Team_B;
		MoveSpeed = 350.0f + Difficulty * 200.0f;

		// Set court bounds for right side
		CourtMinX = 5.0f;
		CourtMaxX = 900.0f;
		CourtMinY = -450.0f;
		CourtMaxY = 450.0f;

		// Reaction delay inversely proportional to difficulty
		ReactionDelay = Math::Lerp(0.8f, 0.1f, Difficulty);
	}

	void Tick(float DeltaTime) override
	{
		Super::Tick(DeltaTime);

		if (Ball == nullptr) FindBall();
		if (Ball == nullptr || !Ball.bInPlay) return;

		ReactionTimer += DeltaTime;
		if (ReactionTimer < ReactionDelay) return;

		UpdateAI(DeltaTime);
	}

	private void UpdateAI(float DeltaTime)
	{
		FVector BallLoc = Ball.GetActorLocation();
		FVector BallVel = Ball.Velocity;
		FVector MyLoc = GetActorLocation();

		// Only care about ball on our side (positive X)
		if (BallLoc.X < 0)
		{
			// Ball on opponent's side - move to ready position
			FVector ReadyPos = FVector(400.0f, 0, FloorZ + PlayerHeight);
			MoveToward(ReadyPos, DeltaTime);
			return;
		}

		// Predict where ball will be
		FVector LandPos = PredictBallPosition(0.5f);

		// Add error based on difficulty (lower difficulty = more error)
		float ErrorRange = (1.0f - Difficulty) * 150.0f;
		LandPos.X += Math::RandRange(-ErrorRange, ErrorRange);
		LandPos.Y += Math::RandRange(-ErrorRange, ErrorRange);

		// Clamp to our court
		LandPos.X = Math::Clamp(LandPos.X, CourtMinX + 50, CourtMaxX - 50);
		LandPos.Y = Math::Clamp(LandPos.Y, CourtMinY + 50, CourtMaxY - 50);

		TargetPosition = FVector(LandPos.X, LandPos.Y, FloorZ + PlayerHeight);
		MoveToward(TargetPosition, DeltaTime);

		// Try to hit if close enough
		if (IsNearBall(Ball))
		{
			DecideHit();
		}
	}

	private void MoveToward(FVector Target, float DeltaTime)
	{
		FVector MyLoc = GetActorLocation();
		FVector Dir = (Target - MyLoc);
		Dir.Z = 0;
		float Dist = Dir.Size2D();

		if (Dist > 10.0f)
		{
			Dir = Dir.GetSafeNormal2D();
			MovePlayer(FVector2D(Dir.X, Dir.Y));
		}
		else
		{
			MovePlayer(FVector2D::ZeroVector);
		}

		// Jump if ball is high
		FVector BallLoc = Ball.GetActorLocation();
		if (BallLoc.Z > PlayerHeight * 1.8f && bIsGrounded && Dist < 200.0f)
			Jump();
	}

	private void DecideHit()
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		int Touches = 0;
		if (GS != nullptr) Touches = GS.TouchesThisRally;

		if (Touches < 2)
		{
			// First or second touch: set up
			TrySet(Ball);
		}
		else
		{
			// Third touch: spike at difficulty-based accuracy
			if (Difficulty > 0.5f)
				TrySpike(Ball);
			else
				TryPass(Ball);
		}
	}

	// Forward-integrate ball trajectory to predict future position
	private FVector PredictBallPosition(float TimeAhead) const
	{
		FVector PPos = Ball.Position;
		FVector PVel = Ball.Velocity;
		float Dt = 0.05f;
		float T = 0;
		float G = Ball.Gravity;

		while (T < TimeAhead)
		{
			PVel.Z += G * Dt;
			PPos += PVel * Dt;
			T += Dt;
			if (PPos.Z <= Ball.FloorZ + Ball.BallRadius)
			{
				PPos.Z = Ball.FloorZ + Ball.BallRadius;
				break;
			}
		}
		return PPos;
	}

	private void FindBall()
	{
		TArray<AActor> Found;
		GetAllActorsOfClass(ABall::StaticClass(), Found);
		if (Found.Num() > 0)
			Ball = Cast<ABall>(Found[0]);
	}
}
