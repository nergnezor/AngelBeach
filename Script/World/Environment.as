// Surrounding environment: the sea, and the SKY DOME that stands in for
// SkyAtmosphere on mobile.
//
// WHY THERE IS A DOME AT ALL. Android has SkyAtmosphere disabled (it wants an
// authored sky mesh; re-enabling it was tested and rendered nothing), so for a
// long time nothing drew the sky and device screenshots had a black band across
// the top of frame. Three attempts to make ExponentialHeightFog cover for it all
// failed — falloff 0.5, 0.2 and 0.02 — because height fog only tints RENDERED
// GEOMETRY. The bright region under the black band was never sky: it was the
// water plane receding to the horizon, fully fogged. The "seam" was the horizon
// itself, and above it there is no geometry for fog to colour. No fog setting
// can paint an empty background.
//
// So the sky needs to BE geometry. This is the same move that fixed the net:
// when an engine feature will not apply on mobile, build the thing out of
// procedural geometry and the one material that is known to work.
//
// The dome sits INSIDE the fog's start distance on purpose. That keeps the
// gradient unfogged, and it also truncates the visible sea to well within the
// same distance — which should finally let the water show its own blue instead
// of the warm haze it has been washed to in every screenshot so far.
class AEnvironment : AActor
{
	UPROPERTY(DefaultComponent, RootComponent)
	USceneComponent Root;

	UPROPERTY(DefaultComponent, Attach = Root)
	UProceduralMeshComponent WaterMesh;

	UPROPERTY(DefaultComponent, Attach = Root)
	UProceduralMeshComponent SkyMesh;

	const float WaterExtent = 60000.0f;   // huge; the dome cuts it off long before this
	const float WaterZ = -5.0f;           // just below the sand

	// Dome radius must clear the whole playfield (sand corners reach ~1580, the
	// match camera sits 1400 out) and stay under the fog's start distance so the
	// gradient is not hazed away.
	//
	// 3000 was too tight. The sand skirt now reaches 900 along the view axis, so
	// it left only ~700 units of sea between the beach and the dome — a sliver
	// that vanished into the horizon, and every sample below the horizon came
	// back sand-coloured. 5000 gives the sea roughly 4000 units to be a sea in.
	// The fog start moves with it (GameMode.as).
	const float SkyRadius    = 5000.0f;
	// 10x24 left the facets plainly visible on device — vertical seams down the
	// sky and stair-steps between bands. The dome is a few thousand triangles
	// either way, so buy the smoothness.
	const int   SkyBands     = 18;
	const int   SkySegments  = 48;
	// Starts below the horizon so the water plane meets the dome wall with no gap
	// (at -30 degrees the dome bottom is z=-1500, far under the water at z=-5).
	const float SkyBottomDeg = -30.0f;

	// THESE BLUES LOOK ABSURD ON PURPOSE — read this before "fixing" them.
	//
	// The scene light is deeply warm (sun 1.0/0.6/0.35, and the sky light bounces
	// off this dome, which is warm too). Measuring the sand pins down what that
	// does: albedo (0.62,0.52,0.36) renders (122,82,43), i.e. a per-channel gain
	// of (0.314,0.162,0.067). Blue comes out at 21% of red. Any honest blue albedo
	// is crushed to grey-brown, which is exactly why the sea has been warm cream
	// in every screenshot and why the zenith band came out (136,81,47) instead of
	// the dark blue it was set to.
	//
	// So the albedos are pre-divided by that gain. Blue above 1.0 is not a
	// mistake: it is what it costs to land a dusk blue through a warm light.
	//   zenith -> linear (0.015,0.035,0.090)
	//   sea    -> linear (0.012,0.030,0.075)
	// If the lighting is ever retuned, re-measure the gain and redo this division
	// rather than eyeballing new numbers.
	private FLinearColor WaterColor = FLinearColor(0.04f, 0.19f, 1.12f, 1.0f);

	private FLinearColor SkyHorizonColor = FLinearColor(0.95f, 0.58f, 0.34f, 1.0f);
	private FLinearColor SkyZenithColor  = FLinearColor(0.05f, 0.22f, 1.34f, 1.0f);

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		BuildSky();
		BuildWater();

		// The vertex-colour engine debug material used here before never applied in
		// a packaged build, so the water rendered in the fallback material's flat
		// cream instead of blue. That is fixed, but the sea STILL measured
		// (234,208,167) on device — flat cream, barely any variation, no blue.
		//
		// A dark blue albedo cannot turn warm cream by being lit, so what is
		// showing is not the albedo: this is a mirror-flat horizontal plane viewed
		// at a grazing angle, which is the worst case for specular. A smooth
		// surface there reflects the bright warm sky straight into the camera and
		// drowns the colour underneath. Roughen it so the sea scatters instead of
		// mirroring, and keep it non-metallic.
		UMaterialInstanceDynamic MID = ApplySolidColorMaterial(WaterMesh, 0, WaterColor);
		if (MID != nullptr)
		{
			MID.SetScalarParameterValue(n"Roughness", 0.55f);
			MID.SetScalarParameterValue(n"Metallic", 0.0f);
		}
	}

	// Deliberate duplicate of ACourt::ApplySolidColorMaterial (see there for why
	// BasicShapeMaterial and what it trades off). It cannot be shared: this fork
	// compiles each .as file as its own module, so a global function is only
	// visible inside its own file — nothing in Script/ calls a global across files.
	private UMaterialInstanceDynamic ApplySolidColorMaterial(UProceduralMeshComponent Comp, int Section, FLinearColor Color)
	{
		if (Comp == nullptr) return nullptr;

		UMaterialInterface Base = Cast<UMaterialInterface>(LoadObject(nullptr,
			"/Engine/BasicShapes/BasicShapeMaterial.BasicShapeMaterial"));
		if (Base == nullptr) return nullptr;

		UMaterialInstanceDynamic MID = Comp.CreateDynamicMaterialInstance(Section, Base);
		if (MID != nullptr)
			MID.SetVectorParameterValue(n"Color", Color);
		return MID;
	}

	// Banded dome: each elevation band is its own mesh section with its own solid
	// colour, so a stepped gradient stands in for a real sky material.
	private void BuildSky()
	{
		// CRITICAL: a closed dome around the whole scene that casts shadows would
		// occlude the directional light — the sun sits at pitch -6, so its rays
		// come in through the dome WALL — and put the entire court in shadow.
		SkyMesh.SetCastShadow(false);

		for (int b = 0; b < SkyBands; b++)
		{
			float t0 = float(b) / float(SkyBands);
			float t1 = float(b + 1) / float(SkyBands);
			float E0 = (SkyBottomDeg + (90.0f - SkyBottomDeg) * t0) * PI / 180.0f;
			float E1 = (SkyBottomDeg + (90.0f - SkyBottomDeg) * t1) * PI / 180.0f;

			TArray<FVector> V; TArray<int32> T; TArray<FVector> N;
			TArray<FVector2D> UV; TArray<FLinearColor> C;
			TArray<FVector2D> NoUV; TArray<FProcMeshTangent> Tan;

			FLinearColor Col = SkyBandColor((t0 + t1) * 0.5f);

			for (int s = 0; s < SkySegments; s++)
			{
				float A0 = 2.0f * PI * s / SkySegments;
				float A1 = 2.0f * PI * (s + 1) / SkySegments;

				int B = V.Num();
				V.Add(SkyPoint(A0, E0)); V.Add(SkyPoint(A1, E0));
				V.Add(SkyPoint(A1, E1)); V.Add(SkyPoint(A0, E1));

				// Both windings. The dome is viewed from the inside, and emitting
				// the back faces too costs a few hundred triangles while making it
				// impossible to get the winding order backwards and end up with an
				// invisible sky.
				T.Add(B+0); T.Add(B+1); T.Add(B+2);
				T.Add(B+0); T.Add(B+2); T.Add(B+3);
				T.Add(B+0); T.Add(B+2); T.Add(B+1);
				T.Add(B+0); T.Add(B+3); T.Add(B+2);

				for (int i = 0; i < 4; i++)
				{
					// Normal up, not outward: the material is lit, and a uniform
					// normal means every band takes identical lighting. The gradient
					// then comes purely from the albedos below, which is predictable
					// — an outward normal would shade each band by its own angle to
					// the sun and fight the gradient.
					N.Add(FVector(0, 0, 1));
					UV.Add(FVector2D(0, 0));
					C.Add(Col);
				}
			}

			SkyMesh.CreateMeshSection_LinearColor(b, V, T, N, UV, NoUV, NoUV, NoUV, C, Tan, false);
			ApplySolidColorMaterial(SkyMesh, b, Col);
		}
	}

	private FVector SkyPoint(float Azimuth, float Elevation) const
	{
		float CosE = Math::Cos(Elevation);
		return FVector(Math::Cos(Azimuth) * CosE * SkyRadius,
			Math::Sin(Azimuth) * CosE * SkyRadius,
			Math::Sin(Elevation) * SkyRadius);
	}

	// Horizon -> zenith, spread over the part of the sky you can actually SEE.
	//
	// T runs 0..1 across the dome's full -30..90 degrees, but the match camera
	// only ever shows about -5 to +45. Both earlier curves ignored that and put
	// the interesting colour off-screen: sqrt(T) climbed too fast and bleached the
	// horizon band, then T*T went the other way and left the top of frame only 39%
	// of the way to zenith blue — measured (169,114,87), still warm, which is why
	// the sky reads as one flat orange.
	//
	// So remap: fully warm at the horizon (T=0.25, elevation 0) and fully at the
	// zenith colour by T=0.60 (elevation 42), with a smoothstep between so the
	// transition has no visible edge. Above that the sky just stays blue, which
	// costs nothing since it is out of frame.
	private FLinearColor SkyBandColor(float T) const
	{
		float k = Math::Clamp((T - 0.25f) / 0.35f, 0.0f, 1.0f);
		k = k * k * (3.0f - 2.0f * k);
		return FLinearColor(
			SkyHorizonColor.R + (SkyZenithColor.R - SkyHorizonColor.R) * k,
			SkyHorizonColor.G + (SkyZenithColor.G - SkyHorizonColor.G) * k,
			SkyHorizonColor.B + (SkyZenithColor.B - SkyHorizonColor.B) * k,
			1.0f);
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
