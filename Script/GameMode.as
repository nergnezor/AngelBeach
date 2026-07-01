// Beach Volleyball Game Mode - spawn, serve flow, scoring, match restart

class ABeachVolleyballGameMode : AGameModeBase
{
	UPROPERTY(BlueprintReadOnly)
	ABall Ball;

	UPROPERTY(BlueprintReadOnly)
	AHumanPlayer HumanPawn;

	UPROPERTY(BlueprintReadOnly)
	AAIPlayer AIPawn;

	UPROPERTY(BlueprintReadOnly)
	ACourt Court;

	UPROPERTY(BlueprintReadOnly)
	ASandFX SandFX;

	float ServeDelay = 2.0f;
	float ServeTimer = 0.0f;
	bool bWaitingForServe = false;
	float MatchRestartDelay = 5.0f;
	float MatchRestartTimer = 0.0f;
	bool bWaitingForRestart = false;

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		SpawnActors();
		StartMatch();
	}

	UFUNCTION(BlueprintOverride)
	void Tick(float DeltaTime)
	{
		if (bWaitingForServe)
		{
			ServeTimer += DeltaTime;
			if (ServeTimer >= ServeDelay)
			{
				bWaitingForServe = false;
				ServeBall();
			}
		}

		if (bWaitingForRestart)
		{
			MatchRestartTimer += DeltaTime;
			if (MatchRestartTimer >= MatchRestartDelay)
			{
				bWaitingForRestart = false;
				ResetMatch();
			}
		}
	}

	private void SpawnActors()
	{
		// Spawn court
		Court = Cast<ACourt>(GetWorld().SpawnActor(ACourt::StaticClass(),
			FVector::ZeroVector, FRotator::ZeroRotator));

		// Spawn sand FX system (dust + upward spray)
		SandFX = Cast<ASandFX>(GetWorld().SpawnActor(ASandFX::StaticClass(),
			FVector::ZeroVector, FRotator::ZeroRotator));

		// Spawn ball
		Ball = Cast<ABall>(GetWorld().SpawnActor(ABall::StaticClass(),
			FVector(0, 0, 300), FRotator::ZeroRotator));
		if (Ball != nullptr)
		{
			Ball.Sand = SandFX;
			Ball.Court = Court;
		}

		// Spawn human player (left/negative X side)
		HumanPawn = Cast<AHumanPlayer>(GetWorld().SpawnActor(AHumanPlayer::StaticClass(),
			FVector(-400, 0, 100), FRotator::ZeroRotator));
		if (HumanPawn != nullptr)
		{
			HumanPawn.Sand = SandFX;
			HumanPawn.Court = Court;
		}

		// Spawn AI player (right/positive X side)
		AIPawn = Cast<AAIPlayer>(GetWorld().SpawnActor(AAIPlayer::StaticClass(),
			FVector(400, 0, 100), FRotator::ZeroRotator));

		if (AIPawn != nullptr)
		{
			AIPawn.Ball = Ball;
			AIPawn.Sand = SandFX;
			AIPawn.Court = Court;
		}

		// Possess human with player controller
		APlayerController PC = Gameplay::GetPlayerController(0);
		if (PC != nullptr && HumanPawn != nullptr)
		{
			PC.Possess(HumanPawn);
			HumanPawn.Ball = Ball;
		}
	}

	private void StartMatch()
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(Gameplay::GetGameState());
		if (GS != nullptr)
		{
			GS.ScoreA = 0;
			GS.ScoreB = 0;
			GS.SetsWonA = 0;
			GS.SetsWonB = 0;
			GS.CurrentSet = 1;
			GS.ServingTeam = ETeam::Team_A;
			GS.GamePhase = EGamePhase::Phase_PreGame;
			GS.MatchWinner = ETeam::Team_None;
		}
		ScheduleServe();
	}

	private void ScheduleServe()
	{
		if (Ball != nullptr)
			Ball.bInPlay = false;

		bWaitingForServe = true;
		ServeTimer = 0;

		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(Gameplay::GetGameState());
		if (GS != nullptr)
			GS.GamePhase = EGamePhase::Phase_Serving;
	}

	private void ServeBall()
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(Gameplay::GetGameState());
		if (GS == nullptr || Ball == nullptr) return;

		FVector ServeOrigin;
		FVector ServeVel;

		if (GS.ServingTeam == ETeam::Team_A)
		{
			ServeOrigin = FVector(-500, 0, 250);
			ServeVel = FVector(400, Math::RandRange(-150.0f, 150.0f), 300);
		}
		else
		{
			ServeOrigin = FVector(500, 0, 250);
			ServeVel = FVector(-400, Math::RandRange(-150.0f, 150.0f), 300);
		}

		Ball.Launch(ServeOrigin, ServeVel);
		GS.StartRally();
	}

	// Called by Ball when it hits floor
	UFUNCTION(BlueprintCallable)
	void OnBallHitFloor(FVector HitPos)
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(Gameplay::GetGameState());
		if (GS == nullptr) return;
		if (GS.GamePhase != EGamePhase::Phase_Rally) return;

		// Determine which team's court the ball landed in
		ETeam ScoringTeam;
		if (HitPos.X < 0)
			ScoringTeam = ETeam::Team_B;  // landed on A's side, B scores
		else
			ScoringTeam = ETeam::Team_A;  // landed on B's side, A scores

		GS.AddPoint(ScoringTeam);

		if (GS.GamePhase == EGamePhase::Phase_MatchOver)
		{
			bWaitingForRestart = true;
			MatchRestartTimer = 0;
		}
		else
		{
			ScheduleServe();
		}
	}

	// Called by Ball when it hits the net
	UFUNCTION(BlueprintCallable)
	void OnBallHitNet()
	{
		// Net touch: rally continues (ball bounces off)
		// If ball falls on same side it came from, that team loses point
	}

	// Called by Player when touch limit exceeded
	UFUNCTION(BlueprintCallable)
	void OnTouchViolation(ETeam FaultingTeam)
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(Gameplay::GetGameState());
		if (GS == nullptr) return;

		ETeam ScoringTeam = (FaultingTeam == ETeam::Team_A) ? ETeam::Team_B : ETeam::Team_A;
		GS.AddPoint(ScoringTeam);
		ScheduleServe();
	}

	private void ResetMatch()
	{
		StartMatch();
	}
}
