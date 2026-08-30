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
// The dome sits INSIDE the fog's start distance on purpose, so the gradient is
// never hazed away.
//
// THE DOME IS ALSO THE SEA, and there is no water plane any more. A flat water
// quad was tried for a long time and never once rendered blue. Measuring at
// x=600 in build 175 settled that it was not being drawn as sea at all: every
// pixel from the horizon down to the sand edge was (193,127,69), the dome's own
// warm horizon band, with no water band anywhere in between.
//
// CORRECTION to what this comment used to claim: BasicShapeMaterial does expose
// a real "Roughness" scalar parameter (checked directly in
// Engine/Content/BasicShapes/BasicShapeMaterial.uasset — it has both a
// MaterialExpressionVectorParameter "Color" and a MaterialExpressionScalarParameter
// "Roughness"), so the SetScalarParameterValue calls were NOT silent no-ops and
// that was never the reason. The quad is gone anyway because a dome band is the
// simpler thing: at these grazing angles a distant wall and a flat plane are
// indistinguishable, and colouring the bands below the horizon as sea removes a
// whole surface — and its reflections — rather than tuning them.
class AEnvironment : AActor
{
	UPROPERTY(DefaultComponent, RootComponent)
	USceneComponent Root;

	UPROPERTY(DefaultComponent, Attach = Root)
	UProceduralMeshComponent SkyMesh;

	UPROPERTY(DefaultComponent, Attach = Root)
	UProceduralMeshComponent WaterMesh;

	UPROPERTY(DefaultComponent, Attach = Root)
	UProceduralMeshComponent BackshoreMesh;

	UPROPERTY(DefaultComponent, Attach = Root)
	UProceduralMeshComponent DuneMesh;

	UPROPERTY(DefaultComponent, Attach = Root)
	UProceduralMeshComponent PropsMesh;

	// THE ISLAND IS A BLOB, not a perfect circle. A true circle read as a
	// perfect ring from above and, worse, from the match camera's low oblique
	// angle it looked SQUARE — the visible arc across the frame is shallow
	// enough at that angle that a true circle and the court's own straight
	// edges underneath it were hard to tell apart. IslandRadius is a per-angle
	// function now (BlobRadius below): three sine harmonics at different
	// frequencies and phases so the coastline wanders in and out without
	// repeating symmetry — a natural-looking outline instead of a gear or a
	// flower, which is what happens with a single harmonic or harmonics that
	// share a phase.
	//
	// Centred on the court (the court is spawned at the world origin —
	// GameMode.as). The sand skirt's furthest corner sits at
	// sqrt(1300^2+900^2) ~= 1581 from centre, and the dune ridge reaches
	// ~1749; verified numerically (see the constants below) that the blob's
	// TIGHTEST point never comes closer than 1913 — clears both with margin
	// at every angle, not just on average. M_Sand and M_Water compute the same
	// BlobRadius(angle) in the shader (parameters "IslandRadius" for the base
	// and "BlobAmplitude" for the wobble) so the wet band, the foam and the
	// water's depth fade all follow the actual wandering coastline rather than
	// a circle that no longer matches the geometry.
	const float IslandRadius = 2300.0f;
	const float IslandBlobAmp = 0.17f;
	const float WaterZ = -40.0f;
	const float WaterHalf = 20000.0f;   // 400 m square ocean

	// Dome radius must clear the whole playfield (sand corners reach ~1580, the
	// match camera sits 1400 out) and stay under the fog's start distance so the
	// gradient is not hazed away.
	// it left only ~700 units of sea between the beach and the dome — a sliver
	// that vanished into the horizon, and every sample below the horizon came
	// back sand-coloured. 5000 gives the sea roughly 4000 units to be a sea in.
	// The fog start moves with it (GameMode.as). (Desktop now uses BuildWater.)
	const float SkyRadius    = 5000.0f;
	// Each band is a separate mesh section, so band count is also the draw-call
	// count for the sky — 40 is a deliberate ceiling. It is needed because a solid
	// colour per band means the gradient can only ever be a staircase, and at 18
	// bands the steps were visible as stripes across the sky. 32 segments is
	// plenty around the horizontal now that the seams sit closer together.
	const int   SkyBands     = 40;
	const int   SkySegments  = 32;
	// The dome runs well below the horizon because these lower bands ARE the sea.
	const float SkyBottomDeg = -30.0f;
	// On desktop only the bands BELOW the waterline are built. Everything above
	// is SkyAtmosphere's job now — see BuildSky().
	const int   SeaBands     = 11;

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
	//   sea    -> linear (0.010,0.023,0.096)
	// If the lighting is ever retuned, re-measure the gain and redo this division
	// rather than eyeballing new numbers.
	private FLinearColor SkySeaColor     = FLinearColor(0.03f, 0.14f, 0.85f, 1.0f);
	private FLinearColor SkyHorizonColor = FLinearColor(0.95f, 0.58f, 0.34f, 1.0f);
	private FLinearColor SkyZenithColor  = FLinearColor(0.05f, 0.22f, 1.34f, 1.0f);

	// DESKTOP sea colours. These are NOT pre-divided: the division above exists to
	// push an honest blue through a deeply warm sunset light, and the desktop sun
	// is now a high, near-neutral midday one. Straight albedos land where they are
	// aimed again. Deep water away from the viewer, hazier toward the waterline —
	// that lightening at the horizon is aerial perspective and it is most of what
	// makes a flat surface read as distance.
	private FLinearColor DeepSeaColor      = FLinearColor(0.015f, 0.055f, 0.110f, 1.0f);
	private FLinearColor WaterlineSeaColor = FLinearColor(0.110f, 0.210f, 0.290f, 1.0f);

	// Same single platform predicate as GameMode::IsMobilePlatform. Duplicated
	// rather than shared because this fork compiles each .as as its own module and
	// a global function is invisible across files (see ApplySolidColorMaterial).
	private bool IsMobile() const
	{
		FString P = Gameplay::GetPlatformName();
		return P == "Android" || P == "IOS";
	}

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		BuildSky();
		if (!IsMobile())
		{
			BuildBackshore();
			BuildWater();
			BuildDunes();
			BuildProps();
		}
	}

	private UMaterialInstanceDynamic ApplyAuthoredMaterial(UProceduralMeshComponent Comp, int Section, FString Path)
	{
		if (Comp == nullptr) return nullptr;
		UMaterialInterface Base = Cast<UMaterialInterface>(LoadObject(nullptr, Path));
		if (Base == nullptr)
		{
			Log("MATERIAL missing: " + Path + " — skipping section");
			return nullptr;
		}
		return Comp.CreateDynamicMaterialInstance(Section, Base);
	}

	// Runtime self-check: does this section's triangle winding actually agree with
	// the per-vertex normals it was built with? BuildBackshore's disc below failed
	// exactly this way (Aug 2026) — correct positions, correct material, but wound
	// backwards because its polar (angle, radius) index pair has the opposite
	// handedness of a plain (X, Y) grid, the same T2.Add(A,Cidx,B)/(B,Cidx,D) pattern
	// that IS correct on the Cartesian grids in this file (Water, Dunes). The whole
	// disc was silently backface-culled from every camera angle, and nothing in the
	// log said so; it took a human noticing the coastline had gone missing by
	// comparing screenshots. Call this once, right after building any FLAT,
	// UP-FACING mesh section (normal ≈ (0,0,1)) — Water, Dunes, Backshore, Lines,
	// Sand all calibrate cleanly against each other. It does NOT reliably
	// generalize to curved or non-planar-normal shapes (see the "no
	// CheckMeshWinding() here" notes on PostsMesh in Court.as and BuildProps
	// below) — don't wire it into those without re-deriving the sign convention
	// for that shape first. Skip BuildSky's dome deliberately too: it emits both
	// windings on purpose (see its comment), so "half the triangles disagree"
	// there is by design, not a bug. A PRIVATE METHOD, duplicated in ACourt for
	// the same module-isolation reason as ApplySolidColorMaterial below.
	private void CheckMeshWinding(FString MeshName, TArray<FVector> V, TArray<int32> T, TArray<FVector> N) const
	{
		int Agree = 0;
		int Disagree = 0;
		for (int i = 0; i + 2 < T.Num(); i += 3)
		{
			FVector A = V[T[i]];
			FVector B = V[T[i + 1]];
			FVector C2 = V[T[i + 2]];
			FVector E1 = B - A;
			FVector E2 = C2 - A;
			FVector Face = FVector(E1.Y * E2.Z - E1.Z * E2.Y,
				E1.Z * E2.X - E1.X * E2.Z, E1.X * E2.Y - E1.Y * E2.X);
			FVector Nrm = N[T[i]];
			if (Face.SizeSquared() < 0.001f || Nrm.SizeSquared() < 0.001f) continue; // degenerate

			// Some meshes here (the net strips, the prop cone) assign a uniform
			// "lit as if flat" normal that is nowhere near the triangle's real
			// geometric plane on purpose. Comparing winding against a normal that
			// is roughly PERPENDICULAR to the triangle tells you nothing either
			// way, so only count triangles where the two are reasonably aligned.
			float Cos = Face.GetSafeNormal().DotProduct(Nrm.GetSafeNormal());
			if (Math::Abs(Cos) < 0.3f) continue; // normal not aligned with this face; inconclusive

			// Calibrated against SandMesh's known-good, known-visible winding
			// (T.Add(A);T.Add(C);T.Add(B) over a +X/+Y grid with normal (0,0,1)):
			// that triangle's (v1-v0)x(v2-v0), dotted with its own normal, comes
			// out NEGATIVE. Every other proven-visible mesh in this file agrees.
			if (Cos < 0.0f) Agree++;
			else Disagree++;
		}

		if (Disagree > Agree)
		{
			Log("WINDING BUG: " + MeshName + " has " + Disagree + "/" + (Agree + Disagree)
				+ " triangles wound backwards from their own normals — this section will "
				+ "render backface-culled (invisible) from the front. Swap two indices per "
				+ "triangle to fix.");
		}
	}

	private UMaterialInstanceDynamic ApplySolidColorMaterial(UProceduralMeshComponent Comp, int Section,
		FLinearColor Color, float Roughness = 0.9f)
	{
		if (Comp == nullptr) return nullptr;

		UMaterialInterface Base = Cast<UMaterialInterface>(LoadObject(nullptr,
			"/Engine/BasicShapes/BasicShapeMaterial.BasicShapeMaterial"));
		if (Base == nullptr) return nullptr;

		UMaterialInstanceDynamic MID = Comp.CreateDynamicMaterialInstance(Section, Base);
		if (MID != nullptr)
		{
			MID.SetVectorParameterValue(n"Color", Color);
			MID.SetScalarParameterValue(n"Roughness", Roughness);
		}
		return MID;
	}

	// Banded dome: each elevation band is its own mesh section with its own solid
	// colour, so a stepped gradient stands in for a real sky material.
	private void BuildSky()
	{
		// CRITICAL: a closed dome around the whole scene that casts shadows would
		// occlude the directional light and put the entire court in shadow.
		SkyMesh.SetCastShadow(false);

		// DESKTOP BUILDS ONLY THE SEA. The dome is opaque geometry at radius 5000
		// and the camera stands inside it, so for as long as it spanned -30..+90
		// degrees it covered the whole upper hemisphere and SkyAtmosphere rendered
		// BEHIND it — invisible. So was the sun disc that SetAtmosphereSunLight
		// enables, which is what the post-process lens flare was aiming at. The
		// SkyLight's real-time capture, meanwhile, only ingests SkyAtmosphere and
		// VolumetricCloud (a lit BasicShapeMaterial is not flagged Is Sky), so the
		// ambient light in the scene came from an atmosphere nobody could see while
		// the visible sky contributed no light at all. That decoupling is why these
		// band colours ever needed hand-calibrating against a measured light gain.
		//
		// Above the waterline is now SkyAtmosphere's job on desktop, and the dome
		// keeps only the job it is genuinely better at: being the sea. Mobile still
		// builds the whole dome — it has no SkyAtmosphere at all.
		bool bMobile = IsMobile();
		// Desktop: a real water plane with Lumen reflections replaces the dome's
		// painted sea bands. Mobile keeps the dome — Etapp 6 adds its stand-in.
		int BandCount = bMobile ? SkyBands : 0;

		for (int b = 0; b < BandCount; b++)
		{
			float t0 = float(b) / float(SkyBands);
			float t1 = float(b + 1) / float(SkyBands);
			float E0 = (SkyBottomDeg + (90.0f - SkyBottomDeg) * t0) * PI / 180.0f;
			float E1 = (SkyBottomDeg + (90.0f - SkyBottomDeg) * t1) * PI / 180.0f;

			TArray<FVector> V; TArray<int32> T; TArray<FVector> N;
			TArray<FVector2D> UV; TArray<FLinearColor> C;
			TArray<FVector2D> NoUV; TArray<FProcMeshTangent> Tan;

			FLinearColor Col = bMobile ? SkyBandColor((t0 + t1) * 0.5f)
			                          : SeaBandColor((t0 + t1) * 0.5f);

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
			// No CheckMeshWinding() here: this band emits BOTH windings on purpose
			// (see the comment above), so "half the triangles disagree" is the
			// intended shape, not the bug that check exists to catch.
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

	// Sea -> warm horizon -> zenith, over the part of the dome you can actually SEE.
	//
	// T runs 0..1 across the dome's full -30..90 degrees, but the match camera
	// shows very little of that. Getting this wrong has put the interesting colour
	// off-screen twice already: sqrt(T) climbed too fast and bleached the horizon,
	// then T*T went the other way and left the top of frame only 39% of the way to
	// blue. Widening it to complete at 42 degrees was still too generous — in the
	// letterboxed 2640x1080 view the top of frame is only about 20 degrees up, and
	// the sky measured (166,121,121) there: mauve, not the intended blue.
	//
	// So the transition completes at 25 degrees, and the band BELOW the horizon
	// runs from the warm strip down into sea blue over about 12 degrees. What you
	// get in frame is the classic sunset stack: dark sea, a bright warm band at
	// the waterline, blue above.
	private FLinearColor SkyBandColor(float T) const
	{
		// Elevation 0 is T=0.25; -12 degrees is T=0.15; +25 degrees is T=0.458.
		if (T <= 0.25f)
		{
			float k = Math::Clamp((T - 0.15f) / 0.10f, 0.0f, 1.0f);
			k = k * k * (3.0f - 2.0f * k);
			return Blend(SkySeaColor, SkyHorizonColor, k);
		}

		float k = Math::Clamp((T - 0.25f) / 0.208f, 0.0f, 1.0f);
		k = k * k * (3.0f - 2.0f * k);
		return Blend(SkyHorizonColor, SkyZenithColor, k);
	}

	// Desktop sea ramp: deep water at the bottom of the dome climbing to a hazier
	// band right under the waterline. T runs 0..1 over the dome's full -30..+90,
	// so the waterline is T=0.25 and SeaBands stops just past it.
	private FLinearColor SeaBandColor(float T) const
	{
		float k = Math::Clamp(T / 0.25f, 0.0f, 1.0f);
		k = k * k * (3.0f - 2.0f * k);
		return Blend(DeepSeaColor, WaterlineSeaColor, k);
	}

	// THE BEACH HAS TO REACH THE HORIZON TOO.
	//
	// The ocean plane is 400m across in BOTH axes, and the court's sand skirt is
	// 26m by 18m. That left water on every side of the court: from the match
	// camera the whole thing read as a sandbar in open sea rather than as a
	// beach, which is less believable than the flat sand-to-nowhere it replaced.
	// A shoreline is a LINE — sea on one side of it, land on the other — so the
	// land needs to be as big as the sea.
	//
	// Sits 2cm below the court sand so the deformable playfield always wins the
	// depth test; the step is far too small to see and it never meets the camera
	// edge-on. Same M_Sand, so the macro variation runs continuously from the
	// court out to the beach without a seam.
	//
	// A DISC, not a rectangle: polar grid, rings from the centre out to
	// IslandRadius, indexed exactly like every other flat grid in this file (ring
	// = outer/row index, segment = inner/fast index) so the winding formula below
	// is the same one already proven correct on the rectangular version of this
	// mesh — see BuildWater's comment for what happens when that assumption is
	// wrong. The innermost ring has radius 0, so every one of its verts sits on
	// the same point; that ring is entirely inside the court's own sand skirt and
	// is never seen.
	private void BuildBackshore()
	{
		BackshoreMesh.SetCastShadow(false);

		const int Rings = 18;
		const int Segs  = 64;
		TArray<FVector> V; TArray<int32> T2; TArray<FVector> Nrm;
		TArray<FVector2D> UV; TArray<FLinearColor> C;
		TArray<FVector2D> NoUV; TArray<FProcMeshTangent> Tan;

		for (int ri = 0; ri <= Rings; ri++)
		{
			for (int sj = 0; sj <= Segs; sj++)
			{
				float Ang = 2.0f * PI * float(sj) / float(Segs);
				// The blob boundary at THIS angle, scaled by how far out this ring
				// sits. Scaling the local (angle-dependent) radius rather than a
				// fixed one keeps every ring's outline the same shape as the
				// coastline, just smaller — no self-intersection, because r grows
				// monotonically with ri at every angle.
				float R = BlobRadius(Ang) * float(ri) / float(Rings);
				V.Add(FVector(Math::Cos(Ang) * R, Math::Sin(Ang) * R, -2.0f));
				Nrm.Add(FVector(0, 0, 1));
				UV.Add(FVector2D(float(ri) / float(Rings), float(sj) / float(Segs)));
				C.Add(FLinearColor(1, 1, 1, 1));
			}
		}
		for (int ri = 0; ri < Rings; ri++)
		{
			for (int sj = 0; sj < Segs; sj++)
			{
				int A = ri * (Segs + 1) + sj;
				int B = A + 1;
				int Cidx = A + Segs + 1;
				int D = Cidx + 1;
				// NOT the same winding as the Cartesian grids in this file (Sand/Water/
				// Dunes all use A,Cidx,B / B,Cidx,D with a fast index along X and a slow
				// index along Y). Here the fast index (sj) runs TANGENTIALLY and the slow
				// index (ri) runs RADIALLY — swapping which axis is "fast" flips the
				// local handedness of the (fast,slow) frame relative to those grids, so
				// the Cartesian-grid triangle order comes out back-facing here and the
				// whole disc was silently backface-culled: from any normal camera angle
				// you saw straight through it to the flat WaterMesh underneath, with only
				// M_Water's own coastline mask (the foam ring) drawn where the island
				// should have been. Reversed (A,B,Cidx / B,D,Cidx) so it faces up.
				T2.Add(A); T2.Add(B); T2.Add(Cidx);
				T2.Add(B); T2.Add(D); T2.Add(Cidx);
			}
		}

		BackshoreMesh.CreateMeshSection_LinearColor(0, V, T2, Nrm, UV, NoUV, NoUV, NoUV, C, Tan, false);
		CheckMeshWinding("BackshoreMesh", V, T2, Nrm);
		UMaterialInstanceDynamic MID = ApplyAuthoredMaterial(BackshoreMesh, 0, "/Game/Materials/M_Sand.M_Sand");
		if (MID != nullptr)
		{
			MID.SetScalarParameterValue(n"IslandRadius", IslandRadius);
			MID.SetScalarParameterValue(n"BlobAmplitude", IslandBlobAmp);
			MID.SetScalarParameterValue(n"WetWidth", 160.0f);
		}
	}

	// Desktop ocean: a vast horizontal plane below the sand so Lumen can reflect
	// the sky and clouds — the painted dome bands never could. Plain square, no
	// shoreline math in the geometry at all: the island disc (BuildBackshore)
	// sits 38cm above this plane and occludes it out to IslandRadius in every
	// direction, and M_Water's own radial mask (IslandRadius) handles the
	// depth-fade and foam ring where the two meet. This used to clip the mesh
	// itself to one side of a straight shoreline, which needed the vertex order
	// mirrored on one axis — that mirroring is what inverted the winding and
	// culled the entire ocean; a plain, symmetric square has no such axis to
	// get wrong.
	private void BuildWater()
	{
		WaterMesh.SetCastShadow(false);

		const int N = 32;
		const float H = WaterHalf;
		TArray<FVector> V; TArray<int32> T; TArray<FVector> Nrm;
		TArray<FVector2D> UV; TArray<FLinearColor> C;
		TArray<FVector2D> NoUV; TArray<FProcMeshTangent> Tan;

		for (int iy = 0; iy <= N; iy++)
		{
			for (int ix = 0; ix <= N; ix++)
			{
				float fx = float(ix) / float(N);
				float fy = float(iy) / float(N);
				V.Add(FVector((fx - 0.5f) * 2.0f * H, (fy - 0.5f) * 2.0f * H, WaterZ));
				Nrm.Add(FVector(0, 0, 1));
				UV.Add(FVector2D(fx, fy));
				C.Add(FLinearColor(1, 1, 1, 1));
			}
		}
		for (int iy = 0; iy < N; iy++)
		{
			for (int ix = 0; ix < N; ix++)
			{
				int A = iy * (N + 1) + ix;
				int B = A + 1;
				int Cidx = A + N + 1;
				int D = Cidx + 1;
				T.Add(A); T.Add(Cidx); T.Add(B);
				T.Add(B); T.Add(Cidx); T.Add(D);
			}
		}

		WaterMesh.CreateMeshSection_LinearColor(0, V, T, Nrm, UV, NoUV, NoUV, NoUV, C, Tan, false);
		CheckMeshWinding("WaterMesh", V, T, Nrm);
		UMaterialInstanceDynamic MID = ApplyAuthoredMaterial(WaterMesh, 0, "/Game/Materials/M_Water.M_Water");
		if (MID != nullptr)
		{
			MID.SetScalarParameterValue(n"IslandRadius", IslandRadius);
			MID.SetScalarParameterValue(n"BlobAmplitude", IslandBlobAmp);
		}
	}

	// Low dunes behind the court (+Y) so the sand does not end in a hard line
	// against the sky when the camera looks along the shoreline.
	private void BuildDunes()
	{
		DuneMesh.SetCastShadow(false);

		const int GX = 24;
		const int GY = 10;
		const float X0 = -900.0f;
		const float X1 = 900.0f;
		const float Y0 = 950.0f;
		const float Y1 = 1500.0f;

		TArray<FVector> V; TArray<int32> T; TArray<FVector> Nrm;
		TArray<FVector2D> UV; TArray<FLinearColor> C;
		TArray<FVector2D> NoUV; TArray<FProcMeshTangent> Tan;

		for (int iy = 0; iy <= GY; iy++)
		{
			for (int ix = 0; ix <= GX; ix++)
			{
				float fx = float(ix) / float(GX);
				float fy = float(iy) / float(GY);
				float X = X0 + fx * (X1 - X0);
				float Y = Y0 + fy * (Y1 - Y0);
				float Z = DuneHeight(X, Y);
				V.Add(FVector(X, Y, Z));
				Nrm.Add(FVector(0, 0, 1));
				UV.Add(FVector2D(fx, fy));
				C.Add(FLinearColor(1, 1, 1, 1));
			}
		}
		for (int iy = 0; iy < GY; iy++)
		{
			for (int ix = 0; ix < GX; ix++)
			{
				int A = iy * (GX + 1) + ix;
				int B = A + 1;
				int Cidx = A + GX + 1;
				int D = Cidx + 1;
				T.Add(A); T.Add(Cidx); T.Add(B);
				T.Add(B); T.Add(Cidx); T.Add(D);
			}
		}

		// Recompute normals from height.
		for (int iy = 1; iy < GY; iy++)
		{
			for (int ix = 1; ix < GX; ix++)
			{
				int I = iy * (GX + 1) + ix;
				float dzx = (V[I + 1].Z - V[I - 1].Z) / ((X1 - X0) / float(GX) * 2.0f);
				float dzy = (V[I + GX + 1].Z - V[I - GX - 1].Z) / ((Y1 - Y0) / float(GY) * 2.0f);
				Nrm[I] = FVector(-dzx, -dzy, 1).GetSafeNormal();
			}
		}

		DuneMesh.CreateMeshSection_LinearColor(0, V, T, Nrm, UV, NoUV, NoUV, NoUV, C, Tan, false);
		CheckMeshWinding("DuneMesh", V, T, Nrm);
		ApplyAuthoredMaterial(DuneMesh, 0, "/Game/Materials/M_Sand.M_Sand");
	}

	// Three sine harmonics at incommensurate frequencies (2, 3, 5) and unrelated
	// phases, weighted so they sum to at most 1.0 in magnitude. MUST MATCH the
	// copy in M_Sand.M_Sand and M_Water.M_Water exactly — verified numerically
	// before picking these constants that the combined minimum never comes
	// closer than 1913 to the centre (see IslandRadius's comment).
	private float BlobRadius(float Ang) const
	{
		float Wobble = 0.5f * Math::Sin(2.0f * Ang + 0.7f)
			+ 0.3f * Math::Sin(3.0f * Ang + 2.1f)
			+ 0.2f * Math::Sin(5.0f * Ang + 4.0f);
		return IslandRadius * (1.0f + IslandBlobAmp * Wobble);
	}

	private float DuneHeight(float X, float Y) const
	{
		float u = (Y - 950.0f) / 550.0f;
		float v = X / 900.0f;
		float h = Math::Sin(u * 3.14159f) * 55.0f;
		h += Math::Sin(v * 6.28318f + 0.4f) * 18.0f;
		h += Math::Cos(u * 9.0f + v * 4.0f) * 10.0f;
		return Math::Max(h * u, 0.0f);
	}

	// Cheap scale references: parasol, towels, a chair, distant palm cards.
	// One mesh section per solid colour — BasicShapeMaterial ignores vertex colour.
	private void BuildProps()
	{
		PropsMesh.SetCastShadow(false);

		// 0: parasol pole
		{
			TArray<FVector> V; TArray<int32> T; TArray<FVector> Nrm;
			TArray<FVector2D> UV; TArray<FLinearColor> C;
			AddPropBox(V, T, Nrm, UV, C, FLinearColor(1,1,1,1),
				FVector(-955, 645, 8), FVector(-945, 655, 260));
			UploadPropSection(0, V, T, Nrm, UV, C,
				FLinearColor(0.15f, 0.15f, 0.16f, 1.0f), 0.55f);
		}
		// 1: parasol canopy + base
		{
			TArray<FVector> V; TArray<int32> T; TArray<FVector> Nrm;
			TArray<FVector2D> UV; TArray<FLinearColor> C;
			AddPropCone(V, T, Nrm, UV, C, FLinearColor(1,1,1,1),
				FVector(-950, 650, 260), 130.0f, 8);
			AddPropBox(V, T, Nrm, UV, C, FLinearColor(1,1,1,1),
				FVector(-980, 620, 0), FVector(-920, 680, 8));
			UploadPropSection(1, V, T, Nrm, UV, C,
				FLinearColor(0.95f, 0.90f, 0.82f, 1.0f), 0.72f);
		}
		// 2: blue towel
		{
			TArray<FVector> V; TArray<int32> T; TArray<FVector> Nrm;
			TArray<FVector2D> UV; TArray<FLinearColor> C;
			AddPropBox(V, T, Nrm, UV, C, FLinearColor(1,1,1,1),
				FVector(-1010, 700, 2), FVector(-930, 760, 4));
			UploadPropSection(2, V, T, Nrm, UV, C,
				FLinearColor(0.18f, 0.45f, 0.72f, 1.0f), 0.80f);
		}
		// 3: white towel
		{
			TArray<FVector> V; TArray<int32> T; TArray<FVector> Nrm;
			TArray<FVector2D> UV; TArray<FLinearColor> C;
			AddPropBox(V, T, Nrm, UV, C, FLinearColor(1,1,1,1),
				FVector(940, -680, 2), FVector(1020, -610, 4));
			UploadPropSection(3, V, T, Nrm, UV, C,
				FLinearColor(0.95f, 0.92f, 0.86f, 1.0f), 0.85f);
		}
		// 4: referee chair
		{
			TArray<FVector> V; TArray<int32> T; TArray<FVector> Nrm;
			TArray<FVector2D> UV; TArray<FLinearColor> C;
			AddPropBox(V, T, Nrm, UV, C, FLinearColor(1,1,1,1),
				FVector(980, 700, 0), FVector(1040, 760, 45));
			AddPropBox(V, T, Nrm, UV, C, FLinearColor(1,1,1,1),
				FVector(990, 710, 45), FVector(1030, 750, 110));
			UploadPropSection(4, V, T, Nrm, UV, C,
				FLinearColor(0.55f, 0.48f, 0.38f, 1.0f), 0.65f);
		}
		// 5: distant palm cards
		{
			TArray<FVector> V; TArray<int32> T; TArray<FVector> Nrm;
			TArray<FVector2D> UV; TArray<FLinearColor> C;
			AddPropCard(V, T, Nrm, UV, C, FLinearColor(1,1,1,1),
				FVector(-1900, -1200, 0), FVector(-1900, -1200, 900), 320.0f);
			AddPropCard(V, T, Nrm, UV, C, FLinearColor(1,1,1,1),
				FVector(1700, -1400, 0), FVector(1700, -1400, 850), 280.0f);
			UploadPropSection(5, V, T, Nrm, UV, C,
				FLinearColor(0.05f, 0.22f, 0.10f, 1.0f), 0.90f);
		}
	}

	private void UploadPropSection(int Section, TArray<FVector> V, TArray<int32> T,
		TArray<FVector> Nrm, TArray<FVector2D> UV, TArray<FLinearColor> C,
		FLinearColor Col, float Rough)
	{
		TArray<FVector2D> NoUV; TArray<FProcMeshTangent> Tan;
		PropsMesh.CreateMeshSection_LinearColor(Section, V, T, Nrm, UV,
			NoUV, NoUV, NoUV, C, Tan, false);
		// No CheckMeshWinding() here, same reason as PostsMesh in Court.as:
		// AddPropBox pairs a bottom quad (Sand-style A,C,B triangulation) with a
		// top quad built the OTHER way (A,B,C) under the same uniform up-normal,
		// so this check disagrees with itself within a single prop, let alone
		// against SandMesh's calibration. These are thin, ground-flush "cheap
		// scale references" (a towel, a chair seat) where a real reversal on one
		// face would likely be as invisible as the post's — not verified either
		// way, left unchecked rather than a claim this method can't back up.
		ApplySolidColorMaterial(PropsMesh, Section, Col, Rough);
	}

	private void AddPropBox(TArray<FVector>& V, TArray<int32>& T, TArray<FVector>& Nrm,
		TArray<FVector2D>& UV, TArray<FLinearColor>& C, FLinearColor Col,
		FVector Min, FVector Max)
	{
		int B = V.Num();
		V.Add(FVector(Min.X, Min.Y, Min.Z)); V.Add(FVector(Max.X, Min.Y, Min.Z));
		V.Add(FVector(Max.X, Max.Y, Min.Z)); V.Add(FVector(Min.X, Max.Y, Min.Z));
		V.Add(FVector(Min.X, Min.Y, Max.Z)); V.Add(FVector(Max.X, Min.Y, Max.Z));
		V.Add(FVector(Max.X, Max.Y, Max.Z)); V.Add(FVector(Min.X, Max.Y, Max.Z));
		T.Add(B+0); T.Add(B+2); T.Add(B+1); T.Add(B+0); T.Add(B+3); T.Add(B+2);
		T.Add(B+4); T.Add(B+5); T.Add(B+6); T.Add(B+4); T.Add(B+6); T.Add(B+7);
		for (int i = 0; i < 8; i++)
		{
			Nrm.Add(FVector(0, 0, 1));
			UV.Add(FVector2D(0, 0));
			C.Add(Col);
		}
	}

	private void AddPropCone(TArray<FVector>& V, TArray<int32>& T, TArray<FVector>& Nrm,
		TArray<FVector2D>& UV, TArray<FLinearColor>& C, FLinearColor Col,
		FVector Apex, float Radius, int Segs)
	{
		int Base = V.Num();
		V.Add(Apex);
		for (int i = 0; i <= Segs; i++)
		{
			float A = 2.0f * PI * float(i) / float(Segs);
			V.Add(Apex + FVector(Math::Cos(A) * Radius, Math::Sin(A) * Radius, 0));
		}
		for (int i = 0; i < Segs; i++)
		{
			T.Add(Base); T.Add(Base + 1 + i); T.Add(Base + 2 + i);
		}
		for (int i = 0; i <= Segs + 1; i++)
		{
			Nrm.Add(FVector(0, 0, 1));
			UV.Add(FVector2D(0, 0));
			C.Add(Col);
		}
	}

	private void AddPropCard(TArray<FVector>& V, TArray<int32>& T, TArray<FVector>& Nrm,
		TArray<FVector2D>& UV, TArray<FLinearColor>& C, FLinearColor Col,
		FVector Base, FVector Top, float HalfW)
	{
		FVector Fwd = (FVector(0, 0, 0) - Base).GetSafeNormal2D();
		FVector Side = FVector(-Fwd.Y, Fwd.X, 0) * HalfW;
		int B = V.Num();
		V.Add(Base - Side); V.Add(Base + Side);
		V.Add(Top + Side); V.Add(Top - Side);
		T.Add(B+0); T.Add(B+1); T.Add(B+2);
		T.Add(B+0); T.Add(B+2); T.Add(B+3);
		for (int i = 0; i < 4; i++)
		{
			Nrm.Add(Fwd);
			UV.Add(FVector2D(0, 0));
			C.Add(Col);
		}
	}

	private FLinearColor Blend(FLinearColor A, FLinearColor B, float K) const
	{
		return FLinearColor(
			A.R + (B.R - A.R) * K,
			A.G + (B.G - A.G) * K,
			A.B + (B.B - A.B) * K,
			1.0f);
	}

}
