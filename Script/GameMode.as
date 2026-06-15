// Beach Volleyball Game Mode - spawn, serve flow, scoring, match restart

class ABeachVolleyballGameMode : AGameModeBase
{
	UPROPERTY(BlueprintReadOnly)
	ABall Ball;

	UPROPERTY(BlueprintReadOnly)
	AHumanPlayer HumanPawn;  // Team A back — AI until gamepad input

	UPROPERTY(BlueprintReadOnly)
	AAIPlayer PlayerA2;  // Team A front

	UPROPERTY(BlueprintReadOnly)
	AAIPlayer PlayerB1;  // Team B back

	UPROPERTY(BlueprintReadOnly)
	AAIPlayer PlayerB2;  // Team B front

	UPROPERTY(BlueprintReadOnly)
	ACourt Court;

	UPROPERTY(BlueprintReadOnly)
	ASandFX SandFX;

	float MatchRestartDelay = 5.0f;

	default HUDClass = ABeachVolleyballHUD;
	default GameStateClass = ABeachVolleyballGameState;
	default DefaultPawnClass = nullptr;

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		SetupWorld();
		SpawnActors();
		StartMatch();
	}

	private void SetupWorld()
	{
		ADirectionalLight SunActor = Cast<ADirectionalLight>(
			SpawnActor(ADirectionalLight, FVector(0, 0, 10000), FRotator(-8, -55, 0)));
		if (SunActor != nullptr)
		{
			UDirectionalLightComponent LC = Cast<UDirectionalLightComponent>(
				SunActor.GetComponentByClass(UDirectionalLightComponent));
			if (LC != nullptr)
			{
				LC.SetIntensity(6.0f);
				LC.SetLightColor(FLinearColor(1.0f, 0.667f, 0.41f));
				LC.CastShadows = true;
			}
		}

		SpawnActor(ASkyAtmosphere, FVector::ZeroVector, FRotator::ZeroRotator);

		ASkyLight SkyLightActor = Cast<ASkyLight>(
			SpawnActor(ASkyLight, FVector(0, 0, 500), FRotator::ZeroRotator));
		if (SkyLightActor != nullptr)
		{
			USkyLightComponent SLC = Cast<USkyLightComponent>(
				SkyLightActor.GetComponentByClass(USkyLightComponent));
			if (SLC != nullptr)
			{
				SLC.SetRealTimeCapture(true);
				SLC.SetIntensity(1.2f);
			}
		}

		AExponentialHeightFog FogActor = Cast<AExponentialHeightFog>(
			SpawnActor(AExponentialHeightFog, FVector(0, 0, 100), FRotator::ZeroRotator));
		if (FogActor != nullptr)
		{
			UExponentialHeightFogComponent FC = Cast<UExponentialHeightFogComponent>(
				FogActor.GetComponentByClass(UExponentialHeightFogComponent));
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

		APostProcessVolume PPV = Cast<APostProcessVolume>(
			SpawnActor(APostProcessVolume, FVector::ZeroVector, FRotator::ZeroRotator));
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

		SpawnActor(ABeachVolleyballCamera, FVector(0, -1400, 350), FRotator(0, 90, 0));
	}

	private void SpawnActors()
	{
		Court = Cast<ACourt>(SpawnActor(ACourt, FVector::ZeroVector, FRotator::ZeroRotator));
		SandFX = Cast<ASandFX>(SpawnActor(ASandFX, FVector::ZeroVector, FRotator::ZeroRotator));

		Ball = Cast<ABall>(SpawnActor(ABall, FVector(0, 0, 300), FRotator::ZeroRotator));
		if (Ball != nullptr)
		{
			Ball.Sand = SandFX;
			Ball.Court = Court;
			Ball.GM = this;
		}

		// Team A: back player = human-controlled (AI until gamepad input)
		HumanPawn = Cast<AHumanPlayer>(SpawnActor(AHumanPlayer, FVector(-600, 100, 90), FRotator::ZeroRotator));
		if (HumanPawn != nullptr)
		{
			HumanPawn.Sand = SandFX;
			HumanPawn.Court = Court;
			HumanPawn.GM = this;
			HumanPawn.Ball = Ball;

			// Possess so input bindings fire, then restore camera as ViewTarget
			APlayerController PC = Gameplay::GetPlayerController(0);
			if (PC != nullptr)
			{
				PC.Possess(HumanPawn);
				// Delay one frame so camera actor exists before we switch to it
				System::SetTimer(this, n"RestoreCamera", 0.05f, bLooping = false);
			}
		}

		PlayerA2 = Cast<AAIPlayer>(SpawnActor(AAIPlayer, FVector(-150, -100, 90), FRotator::ZeroRotator));
		if (PlayerA2 != nullptr)
			PlayerA2.Setup(ETeam::Team_A, EPlayerRole::Role_Front, 0.80f, Ball, SandFX, Court, this);

		// Team B: back player deep right, front player near net right
		PlayerB1 = Cast<AAIPlayer>(SpawnActor(AAIPlayer, FVector(600, -100, 90), FRotator::ZeroRotator));
		if (PlayerB1 != nullptr)
			PlayerB1.Setup(ETeam::Team_B, EPlayerRole::Role_Back, 0.75f, Ball, SandFX, Court, this);

		PlayerB2 = Cast<AAIPlayer>(SpawnActor(AAIPlayer, FVector(150, 100, 90), FRotator::ZeroRotator));
		if (PlayerB2 != nullptr)
			PlayerB2.Setup(ETeam::Team_B, EPlayerRole::Role_Front, 0.80f, Ball, SandFX, Court, this);

		// Wire up teammates so AI can coordinate
		if (PlayerA2 != nullptr && HumanPawn != nullptr) PlayerA2.Teammate = nullptr; // A2's teammate is human
		if (PlayerB1 != nullptr && PlayerB2 != nullptr) { PlayerB1.Teammate = PlayerB2; PlayerB2.Teammate = PlayerB1; }
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
		if (Ball == nullptr) return;
		Ball.bInPlay = false;
		System::SetTimer(this, n"ServeBall", 0.1f, bLooping = false);
	}

	UFUNCTION(BlueprintCallable)
	void ServeBall()
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

	UFUNCTION(BlueprintCallable)
	void OnBallHitFloor(FVector HitPos)
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS == nullptr) return;
		if (GS.GamePhase != EGamePhase::Phase_Rally) return;

		ETeam ScoringTeam;
		if (HitPos.X < 0)
			ScoringTeam = ETeam::Team_B;
		else
			ScoringTeam = ETeam::Team_A;

		GS.AddPoint(ScoringTeam);

		if (GS.GamePhase == EGamePhase::Phase_MatchOver)
		{
			if (Ball != nullptr)
				Ball.StartRestartCountdown(MatchRestartDelay);
		}
		else
		{
			ScheduleServe();
		}
	}

	UFUNCTION(BlueprintCallable)
	void OnBallHitNet() { }

	UFUNCTION(BlueprintCallable)
	void OnTouchViolation(ETeam FaultingTeam)
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS == nullptr) return;

		ETeam ScoringTeam = (FaultingTeam == ETeam::Team_A) ? ETeam::Team_B : ETeam::Team_A;
		GS.AddPoint(ScoringTeam);
		ScheduleServe();
	}

	UFUNCTION(BlueprintCallable)
	void ResetMatch()
	{
		StartMatch();
	}

	UFUNCTION()
	void RestoreCamera()
	{
		APlayerController PC = Gameplay::GetPlayerController(0);
		if (PC == nullptr) return;
		TArray<AActor> Found;
		GetAllActorsOfClass(ABeachVolleyballCamera, Found);
		if (Found.Num() > 0)
			PC.SetViewTargetWithBlend(Found[0], 0.0f);
	}
}
