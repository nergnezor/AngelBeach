// Beach volleyball court - sand, net, lines, posts via ProceduralMeshComponent

class ACourt : AActor
{
	UPROPERTY(DefaultComponent, RootComponent)
	UProceduralMeshComponent SandMesh;

	UPROPERTY(DefaultComponent, Attach = SandMesh)
	UProceduralMeshComponent NetMesh;

	UPROPERTY(DefaultComponent, Attach = SandMesh)
	UProceduralMeshComponent LinesMesh;

	UPROPERTY(DefaultComponent, Attach = SandMesh)
	UProceduralMeshComponent PostsMesh;

	// Court dimensions (cm) - regulation 16m x 8m
	const float CourtHalfLength = 800.0f;   // 16m / 2
	const float CourtHalfWidth  = 400.0f;   //  8m / 2
	const float SandDepth       = 30.0f;
	const float NetHeight       = 243.0f;   // men's net height
	const float NetHalfThick    = 2.5f;
	const float PostHeight      = 260.0f;
	const float PostRadius      = 5.0f;
	const float LineWidth       = 5.0f;

	// Surface colours, driven into a solid-colour material per section
	// (see ACourt::ApplySolidColorMaterial). Plain members, not const: every other const in this
	// file is a primitive, and const object members are not worth the compile risk.
	//
	// These are ALBEDO, not final pixel colours. The values here were originally
	// picked for an unlit vertex-colour material, where the colour IS what you
	// see; the material is lit now, so the sun multiplies them — and 0.93 sand
	// over a bright sunset clipped to near-white, which is why the first working
	// build came out looking like a snowfield. Keep these in the range real
	// surfaces actually reflect (dry sand ~0.5, white line paint ~0.8) and let
	// the lighting do the brightening.
	private FLinearColor SandBaseColor = FLinearColor(0.62f, 0.52f, 0.36f, 1.0f);
	private FLinearColor NetBandColor  = FLinearColor(0.03f, 0.03f, 0.04f, 1.0f);
	private FLinearColor NetTapeColor  = FLinearColor(0.75f, 0.75f, 0.72f, 1.0f);
	private FLinearColor LineColor     = FLinearColor(0.80f, 0.80f, 0.76f, 1.0f);
	// Posts are the exception to the clipping above: measured linear 0.235 at 0.45
	// albedo, so they were sitting at roughly half light, not saturated. They take
	// the -1.5 EV exposure cut at face value where the sand only loses its
	// blow-out, so lift the albedo to keep them from going muddy.
	private FLinearColor PostColor     = FLinearColor(0.65f, 0.62f, 0.56f, 1.0f);

	// --- Deformable sand heightfield ---
	const int   SandGridX    = 80;      // cells along X
	const int   SandGridY    = 48;      // cells along Y
	const float SandMinZ     = -24.0f;  // deepest a crater can go
	const float SandHealRate = 0.35f;   // how fast footprints/craters refill

	private float SandW = 0.0f;         // half-extent X
	private float SandD = 0.0f;         // half-extent Y
	private float SandCellX = 1.0f;
	private float SandCellY = 1.0f;

	// Persistent per-vertex height offset (negative = pushed down).
	private TArray<float> SandHeight;
	private TArray<FVector> SandV;
	private TArray<FVector> SandN;
	private TArray<FVector2D> SandUV;
	private TArray<FProcMeshTangent> SandTan;
	private TArray<FVector2D> NoUV;     // empty UV channels for mesh calls

	private bool bSandDirty = false;
	private float SandUpdateAccum = 0.0f;
	const float SandUpdateInterval = 0.06f;

	// --- Light graphics mode (toggled with B — see ABeachVolleyballGameMode) ----
	// The sand STAYS VISIBLE, frozen (2026-09-06: Erik asked for the mode to
	// read as nicer and clearer — floating lines/net/posts over a plain sky
	// with no ground plane at all cut the one thing a player actually needs,
	// a floor to judge height and footing against). Only the per-frame heal +
	// rebuild is skipped, which is the part that actually costs anything (an
	// 80x48 vertex grid re-uploaded every SandUpdateInterval) — a mesh that
	// is not being re-uploaded costs the same whether it is shown or hidden,
	// same as Net/Lines/Posts already staying visible for free. Water,
	// coastline, dunes and props (Environment.as) are still cut: those are
	// scenery, not the playing surface, and contribute nothing to reading a
	// contact or a footing.
	private bool bLightGraphics = false;

	void SetLightGraphics(bool bOn)
	{
		if (bOn == bLightGraphics) return;
		bLightGraphics = bOn;

		// Footprints and craters keep accumulating in the heightfield while
		// frozen, so coming back to full graphics needs one rebuild to show
		// the current state instead of the shape the sand had when the mode
		// was switched on.
		if (!bOn) bSandDirty = true;
	}

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		BuildSand();
		BuildNet();
		BuildLines();
		BuildPosts();
	}

	UFUNCTION(BlueprintOverride)
	void Tick(float DeltaTime)
	{
		// Hidden sand is not worth healing or re-uploading; SetLightGraphics
		// marks it dirty again on the way out.
		if (bLightGraphics) return;

		// Slowly heal deformations back toward flat.
		bool bAnyHeal = false;
		float HealFactor = 1.0f - Math::Clamp(SandHealRate * DeltaTime, 0.0f, 1.0f);
		for (int i = 0; i < SandHeight.Num(); i++)
		{
			if (Math::Abs(SandHeight[i]) > 0.05f)
			{
				SandHeight[i] *= HealFactor;
				bAnyHeal = true;
			}
			else if (SandHeight[i] != 0.0f)
			{
				SandHeight[i] = 0.0f;
				bAnyHeal = true;
			}
		}
		if (bAnyHeal) bSandDirty = true;

		// Throttle the (relatively heavy) mesh rebuild.
		if (bSandDirty)
		{
			SandUpdateAccum += DeltaTime;
			if (SandUpdateAccum >= SandUpdateInterval)
			{
				SandUpdateAccum = 0.0f;
				bSandDirty = false;
				RebuildSandMesh();
			}
		}
	}

	private int SandIdx(int ix, int iy) const
	{
		return iy * (SandGridX + 1) + ix;
	}

	// Subdivided sand grid so it can be dented into craters and footprints.
	private void BuildSand()
	{
		// NARROWED 2026-09-01, 500 -> 350 (was itself widened from 200 earlier —
		// see the old margin's own history below). Erik asked to bring the whole
		// sand island in to court boundary + 3-4 m; the island's outer coastline
		// (Environment.as::IslandRadius) was resized to match this margin, keeping
		// the same relative safety clearance over the sand skirt and dune ridge
		// the original numbers were solved for — see IslandRadius's comment.
		//
		// At the old +200 the beach ended barely outside the sidelines, so on
		// device the court read as a slab dropped into the sea rather than a
		// court marked out on a beach; +500 fixed that but left a large empty
		// sand apron nobody asked for. +350 keeps "somewhere to sit" without the
		// apron. Grid cells go from ~21 to ~27 cm, still finer than a footprint.
		SandW = CourtHalfLength + 350.0f; // extra sand border
		SandD = CourtHalfWidth + 350.0f;
		SandCellX = (2.0f * SandW) / SandGridX;
		SandCellY = (2.0f * SandD) / SandGridY;

		TArray<int32> T;
		SandV.Empty();
		SandN.Empty();
		SandUV.Empty();
		SandTan.Empty();
		SandHeight.Empty();

		for (int iy = 0; iy <= SandGridY; iy++)
		{
			for (int ix = 0; ix <= SandGridX; ix++)
			{
				float x = -SandW + ix * SandCellX;
				float y = -SandD + iy * SandCellY;
				SandV.Add(FVector(x, y, 0));
				SandN.Add(FVector(0, 0, 1));
				SandUV.Add(FVector2D(float(ix) / SandGridX, float(iy) / SandGridY));
				SandHeight.Add(0.0f);
			}
		}

		for (int iy = 0; iy < SandGridY; iy++)
		{
			for (int ix = 0; ix < SandGridX; ix++)
			{
				int A = SandIdx(ix, iy);
				int B = SandIdx(ix + 1, iy);
				int C = SandIdx(ix + 1, iy + 1);
				int D = SandIdx(ix, iy + 1);
				T.Add(A); T.Add(C); T.Add(B);
				T.Add(A); T.Add(D); T.Add(C);
			}
		}

		SandMesh.CreateMeshSection_LinearColor(0, SandV, T, SandN, SandUV,
			TArray<FVector2D>(), TArray<FVector2D>(), TArray<FVector2D>(),
			SandColors(), SandTan, true, false);
		CheckMeshWinding("SandMesh", SandV, T, SandN);

		// THE SAND HAS ITS OWN MATERIAL NOW. /Game/Materials/M_Sand computes its
		// grain, its macro colour variation and its sparkle from world position in
		// the shader — no textures, so it costs the repo tens of kilobytes and owes
		// nothing to an asset pack — and, crucially, it READS VERTEX COLOUR, which is
		// where SandColors() has been writing crater and footprint shading every
		// frame for as long as the deformation system has existed. BasicShapeMaterial
		// is opaque and ignores vertex colour, so all of that was computed and thrown
		// away; it now shows up for free.
		//
		// Its normal output is WORLD SPACE (bTangentSpaceNormal = false on the asset):
		// SandTan is declared above and never filled, so there is no tangent basis on
		// this mesh — or on any procedural mesh in this project — for a tangent-space
		// normal to be expressed in. The shader perturbs VertexNormalWS instead, which
		// also preserves the crater relief RebuildSandMesh already computes correctly.
		//
		// Falls back to the flat colour if the material is missing — which is what a
		// cook that forgets /Game/Materials looks like. See DefaultGame.ini.
		UMaterialInstanceDynamic SandMID = ApplyAuthoredMaterial(SandMesh, 0,
			"/Game/Materials/M_Sand.M_Sand");
		if (SandMID == nullptr)
		{
			SandMID = ApplySolidColorMaterial(SandMesh, 0, SandBaseColor);
			if (SandMID != nullptr)
			{
				SandMID.SetScalarParameterValue(n"Roughness", 0.95f);
				SandMID.SetScalarParameterValue(n"Metallic", 0.0f);
			}
		}
		else
		{
			// Wet band near the island's edge — see Environment.as::IslandRadius and
			// M_Sand's shoreline mask (Etapp 4). Duplicated rather than shared for
			// the same module-isolation reason as ApplySolidColorMaterial: keep this
			// number in step with Environment.as::IslandRadius by hand.
			// Kept in step with Environment.as::IslandRadius/IslandBlobAmp by hand
			// (module isolation — see ApplySolidColorMaterial's comment). The wet
			// band never actually reaches the court itself at these numbers — the
			// closest sand-skirt corner is ~1373 from centre, comfortably inside
			// even the blob's tightest point at ~1714 (both shrunk 2026-09-01 along
			// with the island — see Environment.as::IslandRadius) — but the shader
			// still needs a real value to evaluate the mask against.
			SandMID.SetScalarParameterValue(n"IslandRadius", 2060.0f);
			SandMID.SetScalarParameterValue(n"BlobAmplitude", 0.17f);
			SandMID.SetScalarParameterValue(n"WetWidth", 160.0f);
		}
	}

	// Per-vertex COMPACTION SHADE for craters and footprints — a mask, not a colour.
	//
	// This used to bake SandBaseColor into the vertex colour, which made the mesh and
	// the material two sources of truth for the same albedo. M_Sand owns the colour
	// now (SandDry/SandDark, plus its own macro variation) and reads this as a plain
	// multiplier, so a footprint is one number in one place. White is undisturbed
	// sand; a full-depth crater comes back at 0.65.
	//
	// The fallback path still works: BasicShapeMaterial ignores vertex colour
	// entirely, so if M_Sand ever fails to load the sand goes flat, not white.
	private TArray<FLinearColor> SandColors() const
	{
		TArray<FLinearColor> C;
		for (int i = 0; i < SandV.Num(); i++)
		{
			float depth = Math::Clamp(-SandHeight[i] / -SandMinZ, 0.0f, 1.0f);
			float shade = 1.0f - depth * 0.35f;
			C.Add(FLinearColor(shade, shade, shade, 1));
		}
		return C;
	}

	// Push the sand down at a world position: crater with a small raised rim.
	UFUNCTION(BlueprintCallable)
	void DeformSand(FVector WorldPos, float Radius, float Depth)
	{
		if (SandHeight.Num() == 0) return;

		FVector Local = WorldPos - GetActorLocation();
		float InvR = (Radius > 1.0f) ? 1.0f / Radius : 1.0f;
		float RimR = Radius * 1.5f;

		int minX = Math::Clamp(int((Local.X - RimR + SandW) / SandCellX) - 1, 0, SandGridX);
		int maxX = Math::Clamp(int((Local.X + RimR + SandW) / SandCellX) + 1, 0, SandGridX);
		int minY = Math::Clamp(int((Local.Y - RimR + SandD) / SandCellY) - 1, 0, SandGridY);
		int maxY = Math::Clamp(int((Local.Y + RimR + SandD) / SandCellY) + 1, 0, SandGridY);

		for (int iy = minY; iy <= maxY; iy++)
		{
			for (int ix = minX; ix <= maxX; ix++)
			{
				int idx = SandIdx(ix, iy);
				FVector P = SandV[idx];
				float d = FVector(P.X - Local.X, P.Y - Local.Y, 0).Size();

				if (d < Radius)
				{
					float t = d * InvR;
					float fall = 1.0f - t * t;
					SandHeight[idx] = Math::Max(SandMinZ, SandHeight[idx] - Depth * fall);
				}
				else if (d < RimR)
				{
					float t = (d - Radius) / (RimR - Radius);
					float rim = (1.0f - t) * Depth * 0.18f;
					SandHeight[idx] += rim;
				}
			}
		}

		bSandDirty = true;
	}

	// Recompute vertex Z + normals from the height grid and push to the mesh.
	private void RebuildSandMesh()
	{
		for (int i = 0; i < SandV.Num(); i++)
		{
			FVector P = SandV[i];
			SandV[i] = FVector(P.X, P.Y, SandHeight[i]);
		}

		for (int iy = 0; iy <= SandGridY; iy++)
		{
			for (int ix = 0; ix <= SandGridX; ix++)
			{
				int xl = Math::Max(ix - 1, 0);
				int xr = Math::Min(ix + 1, SandGridX);
				int yl = Math::Max(iy - 1, 0);
				int yr = Math::Min(iy + 1, SandGridY);
				float dzx = (SandHeight[SandIdx(xr, iy)] - SandHeight[SandIdx(xl, iy)])
					/ ((xr - xl) * SandCellX);
				float dzy = (SandHeight[SandIdx(ix, yr)] - SandHeight[SandIdx(ix, yl)])
					/ ((yr - yl) * SandCellY);
				SandN[SandIdx(ix, iy)] = FVector(-dzx, -dzy, 1).GetSafeNormal();
			}
		}

		SandMesh.UpdateMeshSection_LinearColor(0, SandV, SandN, SandUV,
			TArray<FVector2D>(), TArray<FVector2D>(), TArray<FVector2D>(),
			SandColors(), SandTan, false);
	}

	// Net: a real volleyball net reads as a dark, SEE-THROUGH mesh band with a
	// white top tape — not a solid coloured wall.
	//
	// It gets its transparency from GEOMETRY, not from a translucent material:
	// the band is woven out of thin horizontal and vertical strings with gaps
	// between them, so you look through the holes. That side-steps the whole
	// problem that sank the two previous attempts — M_SimpleTranslucent rendered
	// a solid red sheet, and the engine debug materials do not apply in a
	// packaged build at all (see ACourt::ApplySolidColorMaterial) — since a woven
	// net needs no alpha to be see-through.
	private void BuildNet()
	{
		float HW = CourtHalfWidth + 30.0f;
		const float TapeHeight = 7.0f;                 // white top tape band (cm)
		float BandTop = NetHeight - TapeHeight;        // mesh hangs below the tape
		const float BandBottom = 100.0f;               // net mesh stops ~1m off the sand

		// --- Section 0: the woven net band
		{
			TArray<FVector> V; TArray<int32> T; TArray<FVector> N;
			TArray<FVector2D> UV; TArray<FLinearColor> C; TArray<FProcMeshTangent> Tan;

			// Regulation beach volleyball mesh is ~10 cm square. Slightly coarser
			// here so the string count stays modest on mobile: ~72 verticals plus
			// ~11 horizontals is a few hundred triangles, and at match camera
			// distance the weave reads correctly.
			const float Spacing = 12.0f;   // gap between string centres (cm)
			const float StringW = 1.6f;    // string thickness (cm)

			int VCount = int((2.0f * HW) / Spacing);
			for (int i = 0; i <= VCount; i++)
			{
				float y = -HW + i * Spacing;
				AddNetStrip(V, T, N, UV, C, NetBandColor,
					y - StringW * 0.5f, y + StringW * 0.5f, BandBottom, BandTop);
			}

			int HCount = int((BandTop - BandBottom) / Spacing);
			for (int i = 0; i <= HCount; i++)
			{
				float z = BandBottom + i * Spacing;
				AddNetStrip(V, T, N, UV, C, NetBandColor,
					-HW, HW, z - StringW * 0.5f, z + StringW * 0.5f);
			}

			NetMesh.CreateMeshSection_LinearColor(0, V, T, N, UV, NoUV, NoUV, NoUV, C, Tan, false);
			CheckMeshWinding("NetMesh section 0 (band)", V, T, N);
			ApplySolidColorMaterial(NetMesh, 0, NetBandColor, 0.55f);
		}

		// --- Section 1: white top tape — the classic visual cue for the net line
		{
			TArray<FVector> V; TArray<int32> T; TArray<FVector> N;
			TArray<FVector2D> UV; TArray<FLinearColor> C; TArray<FProcMeshTangent> Tan;

			AddNetStrip(V, T, N, UV, C, NetTapeColor, -HW, HW, BandTop, NetHeight);
			NetMesh.CreateMeshSection_LinearColor(1, V, T, N, UV, NoUV, NoUV, NoUV, C, Tan, false);
			CheckMeshWinding("NetMesh section 1 (tape)", V, T, N);

			ApplySolidColorMaterial(NetMesh, 1, NetTapeColor, 0.72f);
		}
	}

	// One double-sided quad in the net plane (X≈0), spanning Y0..Y1 by Z0..Z1.
	// Appends to the arrays; the CALLER creates the mesh section. (The version
	// this replaced hardcoded vertex indices 0..7 and created section 0 itself,
	// so it could only ever be called once per section — the tape call overwrote
	// the band's geometry and the band never existed as its own section.)
	private void AddNetStrip(TArray<FVector>& V, TArray<int32>& T, TArray<FVector>& N,
		TArray<FVector2D>& UV, TArray<FLinearColor>& C, FLinearColor Col,
		float Y0, float Y1, float Z0, float Z1)
	{
		int B = V.Num();

		// Front face
		V.Add(FVector(-NetHalfThick, Y0, Z0)); V.Add(FVector(-NetHalfThick, Y1, Z0));
		V.Add(FVector(-NetHalfThick, Y1, Z1)); V.Add(FVector(-NetHalfThick, Y0, Z1));
		T.Add(B+0); T.Add(B+1); T.Add(B+2); T.Add(B+0); T.Add(B+2); T.Add(B+3);
		// Back face
		V.Add(FVector( NetHalfThick, Y1, Z0)); V.Add(FVector( NetHalfThick, Y0, Z0));
		V.Add(FVector( NetHalfThick, Y0, Z1)); V.Add(FVector( NetHalfThick, Y1, Z1));
		T.Add(B+4); T.Add(B+5); T.Add(B+6); T.Add(B+4); T.Add(B+6); T.Add(B+7);

		for (int i = 0; i < 8; i++)
		{
			N.Add(FVector(0, 0, 1));
			UV.Add(FVector2D(0, 0));
			C.Add(Col);
		}
	}

	// Court boundary lines and center line
	private void BuildLines()
	{
		TArray<FVector> V;
		TArray<int32> T;
		TArray<FVector> N;
		TArray<FVector2D> UV;
		TArray<FProcMeshTangent> Tan;
		float H = 1.0f; // slightly above sand

		AddLine(V, T, N, UV,
			FVector(-CourtHalfLength, -CourtHalfWidth, H),
			FVector( CourtHalfLength, -CourtHalfWidth, H),
			LineWidth);
		AddLine(V, T, N, UV,
			FVector(-CourtHalfLength,  CourtHalfWidth, H),
			FVector( CourtHalfLength,  CourtHalfWidth, H),
			LineWidth);
		AddLine(V, T, N, UV,
			FVector(-CourtHalfLength, -CourtHalfWidth, H),
			FVector(-CourtHalfLength,  CourtHalfWidth, H),
			LineWidth);
		AddLine(V, T, N, UV,
			FVector( CourtHalfLength, -CourtHalfWidth, H),
			FVector( CourtHalfLength,  CourtHalfWidth, H),
			LineWidth);

		LinesMesh.CreateMeshSection_LinearColor(0, V, T, N, UV,
			TArray<FVector2D>(), TArray<FVector2D>(), TArray<FVector2D>(),
			TArray<FLinearColor>(), Tan, false, false);
		CheckMeshWinding("LinesMesh", V, T, N);

		TArray<FLinearColor> C;
		for (int i = 0; i < V.Num(); i++) C.Add(LineColor);
		LinesMesh.UpdateMeshSection_LinearColor(0, V, N, UV,
			TArray<FVector2D>(), TArray<FVector2D>(), TArray<FVector2D>(),
			C, Tan, false);

		// Never had a material at all — the court lines were drawn in whatever the
		// engine's fallback material happened to look like.
		ApplySolidColorMaterial(LinesMesh, 0, LineColor, 0.68f);
	}

	private void AddLine(TArray<FVector>& Verts, TArray<int32>& Tris,
		TArray<FVector>& Normals, TArray<FVector2D>& UVs,
		FVector A, FVector B, float Width)
	{
		FVector Dir = (B - A).GetSafeNormal();
		FVector Side = FVector(-Dir.Y, Dir.X, 0) * Width * 0.5f;
		int Base = Verts.Num();

		Verts.Add(A - Side); Verts.Add(A + Side);
		Verts.Add(B + Side); Verts.Add(B - Side);

		Tris.Add(Base); Tris.Add(Base+1); Tris.Add(Base+2);
		Tris.Add(Base); Tris.Add(Base+2); Tris.Add(Base+3);

		for (int i = 0; i < 4; i++) Normals.Add(FVector(0,0,1));
		UVs.Add(FVector2D(0,0)); UVs.Add(FVector2D(1,0));
		UVs.Add(FVector2D(1,1)); UVs.Add(FVector2D(0,1));
	}

	// Two cylindrical posts
	private void BuildPosts()
	{
		TArray<FVector> V;
		TArray<int32> T;
		TArray<FVector> N;
		TArray<FVector2D> UV;
		TArray<FProcMeshTangent> Tan;

		int Segs = 8;
		AddCylinder(V, T, N, UV, FVector(0, -CourtHalfWidth - 30.0f, 0), PostRadius, PostHeight, Segs);
		AddCylinder(V, T, N, UV, FVector(0,  CourtHalfWidth + 30.0f, 0), PostRadius, PostHeight, Segs);

		PostsMesh.CreateMeshSection_LinearColor(0, V, T, N, UV,
			TArray<FVector2D>(), TArray<FVector2D>(), TArray<FVector2D>(),
			TArray<FLinearColor>(), Tan, false, false);
		// No CheckMeshWinding() here: it flags every triangle in this cylinder,
		// which the posts visibly contradict — they render fine in every shot.
		// The check is calibrated against SandMesh's flat, up-facing quads
		// (T.Add(A,C,B), a diagonal-first triangulation); AddCylinder builds its
		// side wall with a straight A,B,B+1 fan instead, and that different
		// triangulation choice flips the sign this check keys on even though the
		// posts are (BasicShapeMaterial IS single-sided, confirmed) actually fine.
		// Whether AddCylinder's own winding is truly consistent is a separate,
		// currently-unverified question — a thin post would hide a real reversal
		// (you'd just see the far wall through the near one, same solid colour)
		// the way BackshoreMesh's island never could. Left unchecked rather than
		// asserting an "all clear" this method can't actually back up for curved
		// geometry.

		TArray<FLinearColor> C;
		for (int i = 0; i < V.Num(); i++) C.Add(PostColor);
		PostsMesh.UpdateMeshSection_LinearColor(0, V, N, UV,
			TArray<FVector2D>(), TArray<FVector2D>(), TArray<FVector2D>(),
			C, Tan, false);

		// Never had a material either (same as BuildLines above).
		ApplySolidColorMaterial(PostsMesh, 0, PostColor, 0.38f);
	}

	private void AddCylinder(TArray<FVector>& Verts, TArray<int32>& Tris,
		TArray<FVector>& Normals, TArray<FVector2D>& UVs,
		FVector Base, float Radius, float Height, int Segments)
	{
		int Offset = Verts.Num();
		for (int i = 0; i < Segments; i++)
		{
			float A = 2.0f * PI * i / Segments;
			float Nx = Math::Cos(A);
			float Ny = Math::Sin(A);
			Verts.Add(Base + FVector(Nx * Radius, Ny * Radius, 0));
			Verts.Add(Base + FVector(Nx * Radius, Ny * Radius, Height));
			Normals.Add(FVector(Nx, Ny, 0));
			Normals.Add(FVector(Nx, Ny, 0));
			UVs.Add(FVector2D(float(i)/Segments, 0));
			UVs.Add(FVector2D(float(i)/Segments, 1));
		}
		for (int i = 0; i < Segments; i++)
		{
			int A = Offset + i * 2;
			int B = Offset + ((i + 1) % Segments) * 2;
			Tris.Add(A);   Tris.Add(B);   Tris.Add(B+1);
			Tris.Add(A);   Tris.Add(B+1); Tris.Add(A+1);
		}
	}

	// Shipping-safe solid-colour material for this actor's procedural mesh sections.
	//
	// WHY THIS EXISTS — do not go back to /Engine/EngineDebugMaterials/*:
	// Court.as and Environment.as used to load VertexColorMaterial and
	// M_SimpleUnlitTranslucent from /Engine/EngineDebugMaterials/. Those render fine
	// in the editor but NEVER applied in a packaged Android build: every procedural
	// mesh came out with the engine's own fallback material instead. The give-away is
	// visible in any device screenshot — the sand is the only mesh whose UVs span
	// 0..1 (BuildSand), and it is the only one showing a checkerboard, because the
	// fallback material's checker texture gets stretched across that UV range; every
	// other mesh sets UV (0,0) on all verts, samples one texel, and comes out flat
	// cream (posts, court lines, and the water plane that should be filling the
	// horizon in blue). Force-cooking the debug materials via AlwaysCookMaps did not
	// help — they are editor/debug content and are not usable material assets in a
	// cooked Shipping build.
	//
	// BasicShapeMaterial is ordinary shipping content (it is the material the
	// /Engine/BasicShapes meshes use, and SpawnFallbackBox in VolleyballPlayer.as
	// already relies on it) and exposes a "Color" vector parameter, so a Dynamic
	// Material Instance per section gives each mesh its colour.
	//
	// TRADE-OFFS this makes, both deliberate:
	//  - It is LIT, where the debug materials were unlit. Sand/water now take the
	//    sunset directional light, which is what you want anyway.
	//  - It is OPAQUE and ignores vertex colour. So the sand's per-vertex crater/
	//    footprint darkening (SandColors) and the net band's see-through alpha are
	//    not rendered. The vertex colours are still written into the mesh sections,
	//    so an authored vertex-colour material would bring the crater feedback back
	//    for free. A genuinely see-through net needs either an authored translucent
	//    material or net-shaped geometry (thin strips) instead of a solid quad.
	//
	// A PRIVATE METHOD, deliberately duplicated in AEnvironment rather than shared:
	// this fork compiles each .as file as its own module, so a global function is
	// only visible inside its own file (note nothing in Script/ calls a global across
	// files — MotionPlan.as's MB_* helpers are used only within MotionPlan.as). A
	// shared helper in a new file is worse still: the cook loads scripts via a hot
	// reload, which does not even discover new .as files.
	//
	// Note the material is static-mesh-only: ProceduralMeshComponent is fine (it uses
	// the same local vertex factory), but do NOT use it on the skeletal player mesh —
	// that was tried and rejected at runtime with "missing bUsedWithSkeletalMesh=True!".
	// Typed to UProceduralMeshComponent rather than the UMeshComponent base because
	// this fork's bindings do not implicitly upcast the component handle.
	// Same shape as ApplySolidColorMaterial, but for a material this project owns.
	// Returns nullptr rather than asserting so every caller can fall back to the
	// flat colour: a material loaded by string is invisible to the cook's reference
	// gatherer, so "missing in the packaged build" is a real, quiet failure mode and
	// a flat-coloured court beats a checkerboard one.
	private UMaterialInstanceDynamic ApplyAuthoredMaterial(UProceduralMeshComponent Comp, int Section, FString Path)
	{
		if (Comp == nullptr) return nullptr;
		UMaterialInterface Base = Cast<UMaterialInterface>(LoadObject(nullptr, Path));
		if (Base == nullptr)
		{
			Log("MATERIAL missing: " + Path + " — falling back to flat colour");
			return nullptr;
		}
		return Comp.CreateDynamicMaterialInstance(Section, Base);
	}

	// Runtime self-check: does this section's triangle winding actually agree with
	// the per-vertex normals it was built with? BuildBackshore in Environment.as
	// failed exactly this way (Aug 2026) — correct positions, correct material, but
	// wound backwards because its polar (angle, radius) index pair has the opposite
	// handedness of a plain (X, Y) grid. The whole mesh was silently backface-culled
	// from every camera angle, and nothing in the log said so; it took a human
	// noticing the coastline had gone missing by comparing screenshots. Call this
	// once, right after building any FLAT, UP-FACING mesh section (normal ≈
	// (0,0,1)) — SandMesh, LinesMesh and Environment.as's Water/Dunes/Backshore
	// all calibrate cleanly against each other. It does NOT reliably generalize
	// to curved or non-planar-normal shapes: see the "no CheckMeshWinding() here"
	// note on PostsMesh below before wiring it into anything like a cylinder or
	// cone. A PRIVATE METHOD, duplicated in AEnvironment for the same
	// module-isolation reason as ApplySolidColorMaterial above.
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

			// Some meshes here (the net strips) assign a uniform "lit as if flat"
			// normal that is nowhere near the triangle's real geometric plane on
			// purpose. Comparing winding against a normal that is roughly
			// PERPENDICULAR to the triangle tells you nothing either way, so only
			// count triangles where the two are reasonably aligned.
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

	// Roughness is the second half of what a surface IS, and every caller was
	// leaving it at BasicShapeMaterial's default — so nylon cord, canvas tape,
	// chalk line paint and painted steel all had identical gloss. It costs nothing
	// to be right about it: the material already exposes the parameter.
	private UMaterialInstanceDynamic ApplySolidColorMaterial(UProceduralMeshComponent Comp, int Section, FLinearColor Color, float Roughness = 0.9f)
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
}
