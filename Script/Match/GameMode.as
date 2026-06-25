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

	// Debug: global slow-motion so contact timing / animations are easy to read.
	// Set to 1.0 for normal speed.
	float TimeScale = 1.0f;

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		Gameplay::SetGlobalTimeDilation(TimeScale);
		SetupWorld();
		SpawnActors();
		StartMatch();
	}

	private void SetupWorld()
	{
		// Sun: low on the horizon for a sunset. A low pitch makes SkyAtmosphere paint
		// a warm horizon glow easing to blue overhead (the natural sunset gradient),
		// instead of a flat blue daytime sky. The camera sits at -X looking toward +X,
		// so the sun travels toward -X (yaw 180) to put its disc on the far horizon
		// in front of the camera — that's what the lens flare catches.
		//   pitch -6  = just above the horizon (sunset, not midday)
		//   yaw  180  = light travels -X, sun disc appears toward +X (far court end)
		ADirectionalLight SunActor = Cast<ADirectionalLight>(
			SpawnActor(ADirectionalLight, FVector(0, 0, 10000), FRotator(-6, 180, 0)));
		if (SunActor != nullptr)
		{
			UDirectionalLightComponent LC = Cast<UDirectionalLightComponent>(
				SunActor.GetComponentByClass(UDirectionalLightComponent));
			if (LC != nullptr)
			{
				LC.SetIntensity(6.0f);                                 // bright enough; atmosphere adds glow
				LC.SetLightColor(FLinearColor(1.0f, 0.6f, 0.35f));    // warm low sun
				LC.CastShadows = true;
				LC.SetAtmosphereSunLight(true);                        // visible sun disc for the flare
			}
		}

		// SkyAtmosphere owns the sky: real sun disc (for the lens flare) plus the
		// sunset horizon-glow-to-blue gradient driven by the low sun above.
		SpawnActor(ASkyAtmosphere, FVector::ZeroVector, FRotator::ZeroRotator);

		// Surrounding environment: water plane beyond the sand (sky is the atmosphere).
		SpawnActor(AEnvironment, FVector::ZeroVector, FRotator::ZeroRotator);

		// SkyLight captures the sky for soft ambient fill so the court isn't black.
		ASkyLight SkyLightActor = Cast<ASkyLight>(
			SpawnActor(ASkyLight, FVector(0, 0, 500), FRotator::ZeroRotator));
		if (SkyLightActor != nullptr)
		{
			USkyLightComponent SLC = Cast<USkyLightComponent>(
				SkyLightActor.GetComponentByClass(USkyLightComponent));
			if (SLC != nullptr)
			{
				SLC.SetRealTimeCapture(true);
				SLC.SetIntensity(2.0f);
			}
		}

		// (Single directional light only — a second one triggers UE's "competing
		// directional lights" warning. The bright SkyLight fills the shadows.)

		AExponentialHeightFog FogActor = Cast<AExponentialHeightFog>(
			SpawnActor(AExponentialHeightFog, FVector(0, 0, 100), FRotator::ZeroRotator));
		if (FogActor != nullptr)
		{
			UExponentialHeightFogComponent FC = Cast<UExponentialHeightFogComponent>(
				FogActor.GetComponentByClass(UExponentialHeightFogComponent));
			if (FC != nullptr)
			{
				// Thin, distant haze only — NOT a thick coloured band over the court.
				// The previous dense volumetric fog read as smoke, not a sunset.
				FC.SetFogDensity(0.002f);
				FC.SetFogHeightFalloff(0.5f);
				FC.SetFogInscatteringColor(FLinearColor(0.9f, 0.5f, 0.3f));
				FC.SetVolumetricFog(false);
				FC.SetStartDistance(1500.0f);   // no fog up close; only far away
				FC.SetDirectionalInscatteringColor(FLinearColor(1.0f, 0.55f, 0.25f));
				FC.SetDirectionalInscatteringExponent(8.0f);
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
			PP.BloomIntensity = 0.8f;
			PP.bOverride_BloomThreshold = true;
			PP.BloomThreshold = 1.0f;
			// Brighter exposure window so the COURT is lit, not crushed black to
			// compensate for the bright sky. Bias up and raise the max.
			PP.bOverride_AutoExposureBias = true;
			PP.AutoExposureBias = 1.0f;
			PP.bOverride_AutoExposureMinBrightness = true;
			PP.AutoExposureMinBrightness = 0.5f;
			PP.bOverride_AutoExposureMaxBrightness = true;
			PP.AutoExposureMaxBrightness = 3.0f;
			// Lens flare on the bright sun disc.
			PP.bOverride_LensFlareIntensity = true;
			PP.LensFlareIntensity = 1.0f;
			PP.bOverride_LensFlareBokehSize = true;
			PP.LensFlareBokehSize = 3.0f;
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
		{
			PlayerB1.Setup(ETeam::Team_B, EPlayerRole::Role_Back, 0.75f, Ball, SandFX, Court, this);
			PlayerB1.bDebugAI = true;
			PlayerB1.bDebugHit = true;
		}

		PlayerB2 = Cast<AAIPlayer>(SpawnActor(AAIPlayer, FVector(150, 100, 90), FRotator::ZeroRotator));
		if (PlayerB2 != nullptr)
		{
			PlayerB2.Setup(ETeam::Team_B, EPlayerRole::Role_Front, 0.80f, Ball, SandFX, Court, this);
			PlayerB2.bDebugAI = true;
			PlayerB2.bDebugHit = true;
		}

		// Wire up teammates so AI can coordinate. HumanPawn is now an AAIPlayer,
		// so it pairs with PlayerA2 just like the Team B duo.
		if (PlayerA2 != nullptr && HumanPawn != nullptr) { PlayerA2.Teammate = HumanPawn; HumanPawn.Teammate = PlayerA2; }
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

	// Pause after a dead ball (point won / ball down) before the next serve, so
	// players can reset and the rally has a clear beat.
	float ServeDelay = 5.0f;

	private void ScheduleServe()
	{
		if (Ball == nullptr) return;
		Ball.bInPlay = false;
		System::SetTimer(this, n"ServeBall", ServeDelay, bLooping = false);
	}

	UFUNCTION(BlueprintCallable)
	void ServeBall()
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS == nullptr || Ball == nullptr) return;

		FVector ServeOrigin;
		FVector ServeVel;

		// Serve must clearly clear the 243cm net ~5-8m away. Launch high and with
		// enough horizontal speed: from X=±800 the ball travels ~8m to land deep in
		// the opponent court. Strong forward + strong upward arc.
		if (GS.ServingTeam == ETeam::Team_A)
		{
			ServeOrigin = FVector(-800, 0, 250);
			ServeVel = FVector(850, Math::RandRange(-120.0f, 120.0f), 600);
		}
		else
		{
			ServeOrigin = FVector(800, 0, 250);
			ServeVel = FVector(-850, Math::RandRange(-120.0f, 120.0f), 600);
		}

		Ball.Launch(ServeOrigin, ServeVel);
		GS.StartRally();

		// Track the serve until it clears the net. A serve must go directly over —
		// if it hits the net or lands without crossing, it's a service fault.
		bServePhase = true;
		ServingTeamThisServe = GS.ServingTeam;
	}

	// True from serve launch until the serve has crossed the net (or faulted).
	private bool bServePhase = false;
	private ETeam ServingTeamThisServe = ETeam::Team_None;

	// Called by the ball when it crosses the net plane, so we know the serve was good.
	UFUNCTION(BlueprintCallable)
	void OnBallCrossedNet()
	{
		bServePhase = false;
	}

	UFUNCTION(BlueprintCallable)
	void OnBallHitFloor(FVector HitPos)
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS == nullptr) return;
		if (GS.GamePhase != EGamePhase::Phase_Rally) return;

		ETeam ScoringTeam;
		if (bServePhase)
		{
			// Ball landed while still a serve = it never cleared the net = fault.
			// Point to the receiving team regardless of which side it landed on.
			bServePhase = false;
			ScoringTeam = (ServingTeamThisServe == ETeam::Team_A) ? ETeam::Team_B : ETeam::Team_A;
		}
		else if (HitPos.X < 0)
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
	void OnBallHitNet()
	{
		// A serve that hits the net is a service fault — point to the receiving team.
		if (!bServePhase) return;
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS == nullptr || GS.GamePhase != EGamePhase::Phase_Rally) return;

		bServePhase = false;
		ETeam Receiver = (ServingTeamThisServe == ETeam::Team_A) ? ETeam::Team_B : ETeam::Team_A;
		GS.AddPoint(Receiver);
		ScheduleServe();
	}

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
