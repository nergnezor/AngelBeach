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
		SpawnActor(ADirectionalLight::StaticClass(),
			FVector(0, 0, 10000), FRotator(-8, -55, 0));

		SpawnActor(ASkyAtmosphere::StaticClass(),
			FVector::ZeroVector, FRotator::ZeroRotator);

		SpawnActor(ASkyLight::StaticClass(),
			FVector(0, 0, 500), FRotator::ZeroRotator);

		SpawnActor(AExponentialHeightFog::StaticClass(),
			FVector(0, 0, 100), FRotator::ZeroRotator);
	}

	private void SetupPostProcess()
	{
	}

	private void SpawnCamera()
	{
		SpawnActor(ABeachVolleyballCamera::StaticClass(),
			FVector(0, -1400, 350), FRotator(0, 90, 0));
	}
}
