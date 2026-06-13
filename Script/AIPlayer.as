// AI player - trajectory prediction, role-based team play (front/back)

enum EAIState
{
	AI_Idle,
	AI_Positioning,
	AI_Approach,
	AI_Hitting
}

enum EPlayerRole
{
	Role_Back,   // receives serve, digs, sets from deep
	Role_Front   // attacks, blocks near net
}

class AAIPlayer : AVolleyballPlayer
{
	UPROPERTY(BlueprintReadWrite)
	float Difficulty = 0.75f;  // 0..1

	UPROPERTY(BlueprintReadWrite)
	EPlayerRole Role = EPlayerRole::Role_Back;

	UPROPERTY()
	ABall Ball;

	EAIState AIState = EAIState::AI_Idle;

	float ReactionDelay = 0.0f;
	float ReactionTimer = 0.0f;
	FVector TargetPosition = FVector::ZeroVector;

	// Called by GameMode after spawning to configure this player
	void Setup(ETeam Team, EPlayerRole InRole, float InDifficulty,
		ABall InBall, ASandFX InSand, ACourt InCourt, ABeachVolleyballGameMode InGM)
	{
		TeamSide = Team;
		Role = InRole;
		Difficulty = InDifficulty;
		Ball = InBall;
		Sand = InSand;
		Court = InCourt;
		GM = InGM;
		MoveSpeed = 350.0f + Difficulty * 200.0f;
		ReactionDelay = Math::Lerp(0.7f, 0.08f, Difficulty);

		// Court X extents per team (Team_A = negative X, Team_B = positive X)
		CourtMinY = -450.0f;
		CourtMaxY = 450.0f;

		if (Team == ETeam::Team_A)
		{
			CourtMinX = -900.0f;
			CourtMaxX = -5.0f;
		}
		else
		{
			CourtMinX = 5.0f;
			CourtMaxX = 900.0f;
		}
	}

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		InitPlayer();
		// Default bounds in case Setup() not called yet
		CourtMinX = -900.0f;
		CourtMaxX = -5.0f;
		CourtMinY = -450.0f;
		CourtMaxY = 450.0f;
	}

	UFUNCTION(BlueprintOverride)
	void Tick(float DeltaTime)
	{
		UpdatePlayer(DeltaTime);

		if (Ball == nullptr) FindBall();
		if (Ball == nullptr || !Ball.bInPlay) return;

		ReactionTimer += DeltaTime;
		if (ReactionTimer < ReactionDelay) return;

		UpdateAI(DeltaTime);
	}

	private void UpdateAI(float DeltaTime)
	{
		FVector BallLoc = Ball.GetActorLocation();
		FVector MyLoc = GetActorLocation();

		bool bBallOnMySide = IsOnMySide(BallLoc.X);

		if (!bBallOnMySide)
		{
			// Ball on opponent's side — move to ready position
			MoveToward(ReadyPosition(), DeltaTime);
			return;
		}

		// Ball is on our side
		FVector Predicted = PredictBallPosition(0.5f);

		// Positional error based on difficulty
		float ErrorRange = (1.0f - Difficulty) * 140.0f;
		Predicted.X += Math::RandRange(-ErrorRange, ErrorRange);
		Predicted.Y += Math::RandRange(-ErrorRange, ErrorRange);
		Predicted.X = Math::Clamp(Predicted.X, CourtMinX + 50.0f, CourtMaxX - 50.0f);
		Predicted.Y = Math::Clamp(Predicted.Y, CourtMinY + 50.0f, CourtMaxY - 50.0f);

		// Front player stays near net unless ball is very close to them
		if (Role == EPlayerRole::Role_Front)
		{
			float NetX = CourtMinX < 0 ? -120.0f : 120.0f;
			float BallDist = (BallLoc - MyLoc).Size2D();

			if (BallDist > 200.0f)
			{
				// Stay near net, track ball Y only
				FVector NetPos = FVector(NetX, Math::Clamp(BallLoc.Y, CourtMinY + 80.0f, CourtMaxY - 80.0f),
					FloorZ + PlayerHeight);
				MoveToward(NetPos, DeltaTime);
			}
			else
			{
				MoveToward(FVector(Predicted.X, Predicted.Y, FloorZ + PlayerHeight), DeltaTime);
			}
		}
		else
		{
			// Back player chases the ball
			MoveToward(FVector(Predicted.X, Predicted.Y, FloorZ + PlayerHeight), DeltaTime);
		}

		if (IsNearBall(Ball))
			DecideHit();
	}

	private bool IsOnMySide(float BallX) const
	{
		if (TeamSide == ETeam::Team_A)
			return BallX <= 0.0f;
		return BallX >= 0.0f;
	}

	private FVector ReadyPosition() const
	{
		// Back player retreats deep, front player stays at net
		if (Role == EPlayerRole::Role_Back)
		{
			float X = (TeamSide == ETeam::Team_A) ? -600.0f : 600.0f;
			return FVector(X, 0, FloorZ + PlayerHeight);
		}
		else
		{
			float X = (TeamSide == ETeam::Team_A) ? -150.0f : 150.0f;
			return FVector(X, 0, FloorZ + PlayerHeight);
		}
	}

	private void MoveToward(FVector Target, float DeltaTime)
	{
		FVector MyLoc = GetActorLocation();
		FVector Dir = Target - MyLoc;
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

		// Jump to reach high balls
		if (Ball != nullptr)
		{
			FVector BallLoc = Ball.GetActorLocation();
			if (BallLoc.Z > PlayerHeight * 1.8f && bIsGrounded && Dist < 200.0f)
				Jump();
		}
	}

	private void DecideHit()
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		int Touches = 0;
		if (GS != nullptr) Touches = GS.TouchesThisRally;

		if (Role == EPlayerRole::Role_Front && Touches >= 2)
		{
			// Front player on 3rd touch: spike
			if (Difficulty > 0.4f)
				TrySpike(Ball);
			else
				TrySet(Ball);
		}
		else if (Role == EPlayerRole::Role_Back && Touches == 0)
		{
			// Back player receives: dig/pass up
			TryPass(Ball);
		}
		else if (Touches < 2)
		{
			TrySet(Ball);
		}
		else
		{
			if (Difficulty > 0.5f)
				TrySpike(Ball);
			else
				TryPass(Ball);
		}
	}

	private FVector PredictBallPosition(float TimeAhead) const
	{
		FVector PPos = Ball.Position;
		FVector PVel = Ball.BallVel;
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
		GetAllActorsOfClass(ABall, Found);
		if (Found.Num() > 0)
			Ball = Cast<ABall>(Found[0]);
	}
}
