// Level script: directional light, sky atmosphere, ambient setup

class ACourtLevelScript : ALevelScriptActor
{
	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		SetupLighting();
		SetupPostProcess();
		SpawnCamera();
	}

	private void SetupLighting()
	{
		GetWorld().SpawnActor(ADirectionalLight::StaticClass(),
			FVector(0, 0, 10000), FRotator(-8, -55, 0));

		GetWorld().SpawnActor(ASkyAtmosphere::StaticClass(),
			FVector::ZeroVector, FRotator::ZeroRotator);

		GetWorld().SpawnActor(ASkyLight::StaticClass(),
			FVector(0, 0, 500), FRotator::ZeroRotator);

		GetWorld().SpawnActor(AExponentialHeightFog::StaticClass(),
			FVector(0, 0, 100), FRotator::ZeroRotator);
	}

	private void SetupPostProcess()
	{
	}

	private void SpawnCamera()
	{
		GetWorld().SpawnActor(ABeachVolleyballCamera::StaticClass(),
			FVector(0, -1400, 350), FRotator(0, 90, 0));
	}
}
