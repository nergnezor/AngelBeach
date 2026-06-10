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

	// Draw the score/minimap HUD.
	default HUDClass = ABeachVolleyballHUD;

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		SetupWorld();
		SpawnActors();
		StartMatch();
	}

	// Golden-hour lighting, post-process and side camera (runs on any map).
	private void SetupWorld()
	{
		// --- Sun: low golden-hour angle, warm low-intensity light ---
		ADirectionalLight SunActor = Cast<ADirectionalLight>(
			SpawnActor(ADirectionalLight::StaticClass(), FVector(0, 0, 10000), FRotator(-8, -55, 0)));
		if (SunActor != nullptr)
		{
			UDirectionalLightComponent LC = Cast<UDirectionalLightComponent>(
				SunActor.GetComponentByClass(UDirectionalLightComponent::StaticClass()));
			if (LC != nullptr)
			{
				LC.SetIntensity(6.0f);
				LC.SetLightColor(FLinearColor(1.0f, 0.667f, 0.41f));
				LC.CastShadows = true;
			}
		}

		// --- Sky atmosphere + real-time sky light ---
		SpawnActor(ASkyAtmosphere::StaticClass(), FVector::ZeroVector, FRotator::ZeroRotator);

		ASkyLight SkyLightActor = Cast<ASkyLight>(
			SpawnActor(ASkyLight::StaticClass(), FVector(0, 0, 500), FRotator::ZeroRotator));
		if (SkyLightActor != nullptr)
		{
			USkyLightComponent SLC = Cast<USkyLightComponent>(
				SkyLightActor.GetComponentByClass(USkyLightComponent::StaticClass()));
			if (SLC != nullptr)
			{
				SLC.SetRealTimeCapture(true);
				SLC.SetIntensity(1.2f);
			}
		}

		// --- Warm volumetric fog ---
		AExponentialHeightFog FogActor = Cast<AExponentialHeightFog>(
			SpawnActor(AExponentialHeightFog::StaticClass(), FVector(0, 0, 100), FRotator::ZeroRotator));
		if (FogActor != nullptr)
		{
			UExponentialHeightFogComponent FC = Cast<UExponentialHeightFogComponent>(
				FogActor.GetComponentByClass(UExponentialHeightFogComponent::StaticClass()));
			if (FC != nullptr)
			{
				FC.SetFogDensity(0.012f);
				FC.SetFogHeightFalloff(0.2f);
				FC.SetFogInscatteringColor(FLinearColor(0.85f, 0.55f, 0.35f));
				FC.SetVolumetricFog(true);
				FC.SetVolumetricFogScatteringDistribution(0.85f);
				FC.SetDirectionalInscatteringColor(FLinearColor(1.0f, 0.6f, 0.3f));
				FC.SetDirectionalInscatteringExponent(16.0f);
				FC.SetDirectionalInscatteringStartDistance(100.0f);
			}
		}

		// --- Unbound post-process volume: bloom, exposure, vignette ---
		APostProcessVolume PPV = Cast<APostProcessVolume>(
			SpawnActor(APostProcessVolume::StaticClass(), FVector::ZeroVector, FRotator::ZeroRotator));
		if (PPV != nullptr)
		{
			PPV.bUnbound = true;
			PPV.Priority = 1.0f;
			FPostProcessSettings PP = PPV.Settings;
			PP.bOverride_BloomIntensity = true;
			PP.BloomIntensity = 0.85f;
			PP.bOverride_BloomThreshold = true;
			PP.BloomThreshold = 1.1f;
			PP.bOverride_AutoExposureBias = true;
			PP.AutoExposureBias = 1.0f;
			PP.bOverride_VignetteIntensity = true;
			PP.VignetteIntensity = 0.35f;
			PPV.Settings = PP;
		}

		// --- Side camera ---
		SpawnActor(ABeachVolleyballCamera::StaticClass(), FVector(0, -1400, 350), FRotator(0, 90, 0));
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
		Court = Cast<ACourt>(SpawnActor(ACourt::StaticClass(),
			FVector::ZeroVector, FRotator::ZeroRotator));

		// Spawn sand FX system (dust + upward spray)
		SandFX = Cast<ASandFX>(SpawnActor(ASandFX::StaticClass(),
			FVector::ZeroVector, FRotator::ZeroRotator));

		// Spawn ball
		Ball = Cast<ABall>(SpawnActor(ABall::StaticClass(),
			FVector(0, 0, 300), FRotator::ZeroRotator));
		if (Ball != nullptr)
		{
			Ball.Sand = SandFX;
			Ball.Court = Court;
			Ball.GM = this;
		}

		// Spawn human player (left/negative X side)
		HumanPawn = Cast<AHumanPlayer>(SpawnActor(AHumanPlayer::StaticClass(),
			FVector(-400, 0, 100), FRotator::ZeroRotator));
		if (HumanPawn != nullptr)
		{
			HumanPawn.Sand = SandFX;
			HumanPawn.Court = Court;
			HumanPawn.GM = this;
		}

		// Spawn AI player (right/positive X side)
		AIPawn = Cast<AAIPlayer>(SpawnActor(AAIPlayer::StaticClass(),
			FVector(400, 0, 100), FRotator::ZeroRotator));
		if (AIPawn != nullptr)
		{
			AIPawn.Ball = Ball;
			AIPawn.Sand = SandFX;
			AIPawn.Court = Court;
			AIPawn.GM = this;
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
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
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

		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS != nullptr)
			GS.GamePhase = EGamePhase::Phase_Serving;
	}

	private void ServeBall()
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
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
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
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
	}

	// Called by Player when touch limit exceeded
	UFUNCTION(BlueprintCallable)
	void OnTouchViolation(ETeam FaultingTeam)
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
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
