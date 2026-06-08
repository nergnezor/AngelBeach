// Level script: directional light, sky atmosphere, ambient setup

class ACourtLevelScript : ALevelScriptActor
{
	UPROPERTY()
	UDirectionalLightComponent SunLight;

	UPROPERTY()
	USkyAtmosphereComponent SkyAtmosphere;

	UPROPERTY()
	UExponentialHeightFogComponent HeightFog;

	void BeginPlay() override
	{
		Super::BeginPlay();
		SetupLighting();
		SetupPostProcess();
		SpawnCamera();
	}

	// Golden-hour beach lighting: low warm sun, glowing sky, warm volumetric fog.
	private void SetupLighting()
	{
		FActorSpawnParameters Params;

		// --- Sun: low golden-hour angle, warm low-intensity light ---
		// Pitch ~ -8 deg keeps the sun near the horizon for long raking shadows.
		ADirectionalLight SunActor = Cast<ADirectionalLight>(
			GetWorld().SpawnActor(ADirectionalLight::StaticClass(),
				FVector(0, 0, 10000), FRotator(-8, -55, 0), Params));

		if (SunActor != nullptr)
		{
			UDirectionalLightComponent LC = SunActor.GetComponentByClass(UDirectionalLightComponent::StaticClass());
			if (LC != nullptr)
			{
				LC.Intensity = 6.0f;                    // softer than midday
				LC.LightColor = FColor(255, 170, 105);  // warm orange sunset
				LC.AtmosphereSunLight = true;
				LC.bCastShadows = true;
				LC.bUseTemperature = true;
				LC.Temperature = 5200.0f;               // warm white point
			}
		}

		// --- Sky atmosphere: physically-based sky, colours follow the low sun ---
		GetWorld().SpawnActor(ASkyAtmosphere::StaticClass(),
			FVector::ZeroVector, FRotator::ZeroRotator, Params);

		// --- Sky light: real-time capture so ambient matches the warm sky ---
		ASkyLight SkyLightActor = Cast<ASkyLight>(
			GetWorld().SpawnActor(ASkyLight::StaticClass(),
				FVector(0, 0, 500), FRotator::ZeroRotator, Params));

		if (SkyLightActor != nullptr)
		{
			USkyLightComponent SLC = SkyLightActor.GetComponentByClass(USkyLightComponent::StaticClass());
			if (SLC != nullptr)
			{
				SLC.bRealTimeCapture = true;
				SLC.Intensity = 1.2f;
			}
		}

		// --- Warm volumetric fog with directional inscattering (god-ray glow) ---
		AExponentialHeightFog FogActor = Cast<AExponentialHeightFog>(
			GetWorld().SpawnActor(AExponentialHeightFog::StaticClass(),
				FVector(0, 0, 100), FRotator::ZeroRotator, Params));

		if (FogActor != nullptr)
		{
			UExponentialHeightFogComponent FC =
				FogActor.GetComponentByClass(UExponentialHeightFogComponent::StaticClass());
			if (FC != nullptr)
			{
				FC.FogDensity = 0.012f;
				FC.FogHeightFalloff = 0.2f;
				FC.FogInscatteringColor = FLinearColor(0.85f, 0.55f, 0.35f);  // warm haze
				FC.bEnableVolumetricFog = true;
				FC.VolumetricFogScatteringDistribution = 0.85f;               // forward glow
				FC.DirectionalInscatteringColor = FLinearColor(1.0f, 0.6f, 0.3f);
				FC.DirectionalInscatteringExponent = 16.0f;
				FC.DirectionalInscatteringStartDistance = 100.0f;
			}
		}
	}

	// Unbound post-process volume for exposure, bloom and a touch of vignette.
	// Only simple float overrides are used to keep script compilation robust.
	private void SetupPostProcess()
	{
		FActorSpawnParameters Params;
		APostProcessVolume PPV = Cast<APostProcessVolume>(
			GetWorld().SpawnActor(APostProcessVolume::StaticClass(),
				FVector::ZeroVector, FRotator::ZeroRotator, Params));

		if (PPV == nullptr) return;

		PPV.bUnbound = true;
		PPV.Priority = 1.0f;

		FPostProcessSettings PP = PPV.Settings;

		PP.bOverride_BloomIntensity = true;
		PP.BloomIntensity = 0.85f;
		PP.bOverride_BloomThreshold = true;
		PP.BloomThreshold = 1.1f;

		PP.bOverride_AutoExposureBias = true;
		PP.AutoExposureBias = 1.0f;        // slightly bright, sun-soaked look

		PP.bOverride_VignetteIntensity = true;
		PP.VignetteIntensity = 0.35f;

		PPV.Settings = PP;
	}

	private void SpawnCamera()
	{
		FActorSpawnParameters Params;
		GetWorld().SpawnActor(ABeachVolleyballCamera::StaticClass(),
			FVector(0, -1400, 350), FRotator(0, 90, 0), Params);
	}
}
