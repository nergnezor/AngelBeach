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
		SpawnCamera();
	}

	private void SetupLighting()
	{
		// Spawn directional light (sun)
		FActorSpawnParameters Params;
		ADirectionalLight SunActor = Cast<ADirectionalLight>(
			GetWorld().SpawnActor(ADirectionalLight::StaticClass(),
				FVector(0, 0, 10000), FRotator(-55, 45, 0), Params));

		if (SunActor != nullptr)
		{
			UDirectionalLightComponent LC = SunActor.GetComponentByClass(UDirectionalLightComponent::StaticClass());
			if (LC != nullptr)
			{
				LC.Intensity = 10.0f;
				LC.LightColor = FColor(255, 245, 210); // warm sunlight
				LC.AtmosphereSunLight = true;
				LC.bCastShadows = true;
			}
		}

		// Spawn sky atmosphere
		ASkyAtmosphere SkyAtm = Cast<ASkyAtmosphere>(
			GetWorld().SpawnActor(ASkyAtmosphere::StaticClass(),
				FVector::ZeroVector, FRotator::ZeroRotator, Params));

		// Spawn sky light
		ASkyLight SkyLightActor = Cast<ASkyLight>(
			GetWorld().SpawnActor(ASkyLight::StaticClass(),
				FVector(0, 0, 500), FRotator::ZeroRotator, Params));

		if (SkyLightActor != nullptr)
		{
			USkyLightComponent SLC = SkyLightActor.GetComponentByClass(USkyLightComponent::StaticClass());
			if (SLC != nullptr)
			{
				SLC.bRealTimeCapture = true;
				SLC.Intensity = 1.0f;
			}
		}

		// Spawn height fog for atmosphere
		AExponentialHeightFog FogActor = Cast<AExponentialHeightFog>(
			GetWorld().SpawnActor(AExponentialHeightFog::StaticClass(),
				FVector(0, 0, 100), FRotator::ZeroRotator, Params));

		if (FogActor != nullptr)
		{
			UExponentialHeightFogComponent FC =
				FogActor.GetComponentByClass(UExponentialHeightFogComponent::StaticClass());
			if (FC != nullptr)
			{
				FC.FogDensity = 0.005f;
				FC.FogInscatteringColor = FLinearColor(0.5f, 0.7f, 1.0f);
				FC.FogHeightFalloff = 0.2f;
			}
		}
	}

	private void SpawnCamera()
	{
		FActorSpawnParameters Params;
		GetWorld().SpawnActor(ABeachVolleyballCamera::StaticClass(),
			FVector(0, -1400, 350), FRotator(0, 90, 0), Params);
	}
}
