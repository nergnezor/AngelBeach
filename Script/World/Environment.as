// Surrounding environment: a large water plane filling the land beyond the sand.
// The SKY is owned by SkyAtmosphere (spawned in GameMode) — it provides the real
// sun disc + horizon glow for the lens flare. A procedural gradient dome was tried
// here but it just fought the atmosphere (which paints over it), so it was removed;
// only the water remains. Water uses an unlit vertex-colour material.
class AEnvironment : AActor
{
	UPROPERTY(DefaultComponent, RootComponent)
	USceneComponent Root;

	UPROPERTY(DefaultComponent, Attach = Root)
	UProceduralMeshComponent WaterMesh;

	const float WaterExtent = 60000.0f;   // huge, reaches the horizon
	const float WaterZ = -5.0f;           // just below the sand

	// Dusky blue water that picks up a little warm sunset.
	private FLinearColor WaterColor = FLinearColor(0.10f, 0.20f, 0.32f, 1.0f);

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		BuildWater();

		// The vertex-colour engine debug material used here before never applied in
		// a packaged build, so the water rendered in the fallback material's flat
		// cream instead of blue — which is why the horizon had no water in it at
		// all on device. see the ApplySolidColorMaterial helper at the bottom of Court.as.
		ApplySolidColorMaterial(WaterMesh, 0, WaterColor);
	}

	// Flat water plane (a big quad) tinted a deep sunset-reflecting teal/blue with a
	// warm sheen — vertex colour only, kept simple.
	private void BuildWater()
	{
		TArray<FVector> V;
		TArray<int32> T;
		TArray<FVector> N;
		TArray<FVector2D> UV;
		TArray<FLinearColor> C;
		TArray<FVector2D> NoUV;
		TArray<FProcMeshTangent> Tan;

		float E = WaterExtent;
		V.Add(FVector(-E, -E, WaterZ)); V.Add(FVector( E, -E, WaterZ));
		V.Add(FVector( E,  E, WaterZ)); V.Add(FVector(-E,  E, WaterZ));
		for (int i = 0; i < 4; i++) { N.Add(FVector(0, 0, 1)); UV.Add(FVector2D(0, 0)); }

		for (int i = 0; i < 4; i++) C.Add(WaterColor);

		T.Add(0); T.Add(1); T.Add(2);
		T.Add(0); T.Add(2); T.Add(3);

		WaterMesh.CreateMeshSection_LinearColor(0, V, T, N, UV, NoUV, NoUV, NoUV, C, Tan, false);
	}
}
