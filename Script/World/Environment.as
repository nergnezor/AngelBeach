// Surrounding environment: a large water plane filling the land beyond the sand,
// and a gradient sky dome. Both procedural with vertex colours and an unlit
// vertex-colour material so the look is exact and not washed out by lighting.
class AEnvironment : AActor
{
	UPROPERTY(DefaultComponent, RootComponent)
	USceneComponent Root;

	UPROPERTY(DefaultComponent, Attach = Root)
	UProceduralMeshComponent WaterMesh;

	UPROPERTY(DefaultComponent, Attach = Root)
	UProceduralMeshComponent SkyMesh;

	const float WaterExtent = 60000.0f;   // huge, reaches the horizon
	const float WaterZ = -5.0f;           // just below the sand
	const float SkyRadius = 50000.0f;

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		UMaterialInterface VCMat = Cast<UMaterialInterface>(LoadObject(nullptr,
			"/Engine/EngineDebugMaterials/VertexColorMaterial.VertexColorMaterial"));

		BuildWater();
		BuildSky();

		if (VCMat != nullptr)
		{
			WaterMesh.SetMaterial(0, VCMat);
			SkyMesh.SetMaterial(0, VCMat);
		}
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

		// Dusky blue water that picks up a little warm sunset.
		FLinearColor Water = FLinearColor(0.10f, 0.20f, 0.32f, 1.0f);
		for (int i = 0; i < 4; i++) C.Add(Water);

		T.Add(0); T.Add(1); T.Add(2);
		T.Add(0); T.Add(2); T.Add(3);

		WaterMesh.CreateMeshSection_LinearColor(0, V, T, N, UV, NoUV, NoUV, NoUV, C, Tan, false);
	}

	// Inward-facing sky dome with a soft vertical sunset gradient.
	private void BuildSky()
	{
		TArray<FVector> V;
		TArray<int32> T;
		TArray<FVector> N;
		TArray<FVector2D> UV;
		TArray<FLinearColor> C;
		TArray<FVector2D> NoUV;
		TArray<FProcMeshTangent> Tan;

		int Stacks = 24;
		int Slices = 32;

		for (int i = 0; i <= Stacks; i++)
		{
			float Phi = PI * i / Stacks;
			float CosPhi = Math::Cos(Phi);
			for (int j = 0; j <= Slices; j++)
			{
				float Theta = 2.0f * PI * j / Slices;
				FVector Dir = FVector(
					Math::Sin(Phi) * Math::Cos(Theta),
					Math::Sin(Phi) * Math::Sin(Theta),
					CosPhi);
				V.Add(Dir * SkyRadius);
				N.Add(Dir * -1.0f);
				UV.Add(FVector2D(float(j) / Slices, float(i) / Stacks));
				float Height = Math::Clamp(CosPhi, 0.0f, 1.0f);  // 0 horizon -> 1 zenith
				C.Add(SkyColor(Height));
			}
		}

		for (int i = 0; i < Stacks; i++)
		{
			for (int j = 0; j < Slices; j++)
			{
				int A = i * (Slices + 1) + j;
				int B = A + 1;
				int Cc = A + Slices + 1;
				int D = Cc + 1;
				T.Add(A); T.Add(B); T.Add(Cc);
				T.Add(B); T.Add(D); T.Add(Cc);
			}
		}

		SkyMesh.CreateMeshSection_LinearColor(0, V, T, N, UV, NoUV, NoUV, NoUV, C, Tan, false);
	}

	// Soft, natural sunset: warm near the horizon easing up through rose to a calm
	// deep blue/indigo overhead — desaturated enough to avoid the "piss yellow" look.
	private FLinearColor SkyColor(float t) const
	{
		FLinearColor Horizon = FLinearColor(0.95f, 0.55f, 0.35f);   // warm peach
		FLinearColor Mid     = FLinearColor(0.70f, 0.40f, 0.50f);   // dusty rose
		FLinearColor High    = FLinearColor(0.20f, 0.22f, 0.42f);   // deep indigo

		if (t < 0.45f)
		{
			float k = t / 0.45f;
			return Lerp(Horizon, Mid, k);
		}
		float k = (t - 0.45f) / 0.55f;
		return Lerp(Mid, High, k);
	}

	private FLinearColor Lerp(FLinearColor A, FLinearColor B, float k) const
	{
		return FLinearColor(
			A.R + (B.R - A.R) * k,
			A.G + (B.G - A.G) * k,
			A.B + (B.B - A.B) * k,
			1.0f);
	}
}
