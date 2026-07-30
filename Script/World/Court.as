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
		SandW = CourtHalfLength + 200.0f; // extra sand border
		SandD = CourtHalfWidth + 200.0f;
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

		// SandMesh never had a material assigned, on any platform — an unassigned
		// ProceduralMeshComponent section renders with the engine's checkerboard
		// "no material" placeholder, and SandColors() (the per-vertex sand tint /
		// crater-darkening feedback from footsteps) was computed but never seen.
		// VertexColorMaterial is Unlit and reads vertex colour directly, so it
		// shows the real sand colour without depending on scene lighting — same
		// material BuildNet() already uses below for the same reason.
		UMaterialInterface SandMat = Cast<UMaterialInterface>(LoadObject(nullptr,
			"/Engine/EngineDebugMaterials/VertexColorMaterial.VertexColorMaterial"));
		if (SandMat != nullptr)
			SandMesh.SetMaterial(0, SandMat);
	}

	// Sand colour, darkened slightly inside craters (compacted/shadowed sand).
	private TArray<FLinearColor> SandColors() const
	{
		TArray<FLinearColor> C;
		for (int i = 0; i < SandV.Num(); i++)
		{
			float depth = Math::Clamp(-SandHeight[i] / -SandMinZ, 0.0f, 1.0f);
			float shade = 1.0f - depth * 0.35f;
			C.Add(FLinearColor(0.93f * shade, 0.83f * shade, 0.60f * shade, 1));
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

	// Net: a real volleyball net reads as a dark, see-through mesh band with a
	// white top tape — NOT a solid coloured wall. The previous version used the
	// engine debug material M_SimpleTranslucent, which ignores vertex colour and
	// rendered as a solid red sheet. Here the net band sits just under the top
	// (NetMeshTopZ..NetHeight is the white tape; the band hangs below it) and uses
	// the unlit vertex-colour material so the colour + alpha actually apply.
	private void BuildNet()
	{
		float HW = CourtHalfWidth + 30.0f;
		const float TapeHeight = 7.0f;                 // white top tape band (cm)
		float BandTop = NetHeight - TapeHeight;        // mesh hangs below the tape
		const float BandBottom = 100.0f;               // net mesh stops ~1m off the sand

		// --- Section 0: net mesh band, dark + mostly transparent (you see through it)
		{
			TArray<FVector> V; TArray<int32> T; TArray<FVector> N;
			TArray<FVector2D> UV; TArray<FLinearColor> C; TArray<FProcMeshTangent> Tan;
			FLinearColor MeshColor = FLinearColor(0.02f, 0.02f, 0.02f, 0.45f); // near-black, ~45% opaque

			AddNetQuad(V, T, N, UV, C, MeshColor, BandBottom, BandTop, HW);
			NetMesh.CreateMeshSection_LinearColor(0, V, T, N, UV, NoUV, NoUV, NoUV, C, Tan, false);

			UMaterialInterface NetMat = Cast<UMaterialInterface>(LoadObject(nullptr,
				"/Engine/EngineDebugMaterials/M_SimpleUnlitTranslucent.M_SimpleUnlitTranslucent"));
			if (NetMat != nullptr)
			{
				UMaterialInstanceDynamic MID = NetMesh.CreateDynamicMaterialInstance(0, NetMat);
				if (MID != nullptr)
					MID.SetVectorParameterValue(n"Color", MeshColor);
			}
		}

		// --- Section 1: opaque white top tape — the classic visual cue for the net line
		{
			TArray<FVector> V; TArray<int32> T; TArray<FVector> N;
			TArray<FVector2D> UV; TArray<FLinearColor> C; TArray<FProcMeshTangent> Tan;
			FLinearColor White = FLinearColor(0.95f, 0.95f, 0.95f, 1.0f);

			AddNetQuad(V, T, N, UV, C, White, BandTop, NetHeight, HW);
			NetMesh.CreateMeshSection_LinearColor(1, V, T, N, UV, NoUV, NoUV, NoUV, C, Tan, false);

			UMaterialInterface VCMat = Cast<UMaterialInterface>(LoadObject(nullptr,
				"/Engine/EngineDebugMaterials/VertexColorMaterial.VertexColorMaterial"));
			if (VCMat != nullptr)
				NetMesh.SetMaterial(1, VCMat);
		}
	}

	// Double-sided vertical quad in the net plane (X=0), spanning Z0..Z1 across the
	// full width ±HW, with the given vertex colour.
	private void AddNetQuad(TArray<FVector>& V, TArray<int32>& T, TArray<FVector>& N,
		TArray<FVector2D>& UV, TArray<FLinearColor>& C, FLinearColor Col,
		float Z0, float Z1, float HW)
	{
		TArray<FProcMeshTangent> Tan;
		TArray<FVector2D> EmptyUV;

		// Front face
		V.Add(FVector(-NetHalfThick, -HW, Z0)); V.Add(FVector(-NetHalfThick,  HW, Z0));
		V.Add(FVector(-NetHalfThick,  HW, Z1)); V.Add(FVector(-NetHalfThick, -HW, Z1));
		T.Add(0); T.Add(1); T.Add(2); T.Add(0); T.Add(2); T.Add(3);
		// Back face
		V.Add(FVector( NetHalfThick,  HW, Z0)); V.Add(FVector( NetHalfThick, -HW, Z0));
		V.Add(FVector( NetHalfThick, -HW, Z1)); V.Add(FVector( NetHalfThick,  HW, Z1));
		T.Add(4); T.Add(5); T.Add(6); T.Add(4); T.Add(6); T.Add(7);

		for (int i = 0; i < 8; i++)
		{
			N.Add(FVector(0, 0, 1));
			UV.Add(FVector2D(0, 0));
			C.Add(Col);
		}

		NetMesh.CreateMeshSection_LinearColor(0, V, T, N, UV,
			EmptyUV, EmptyUV, EmptyUV, C, Tan, false, false);
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

		TArray<FLinearColor> C;
		for (int i = 0; i < V.Num(); i++) C.Add(FLinearColor(1,1,1,1));
		LinesMesh.UpdateMeshSection_LinearColor(0, V, N, UV,
			TArray<FVector2D>(), TArray<FVector2D>(), TArray<FVector2D>(),
			C, Tan, false);
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

		TArray<FLinearColor> C;
		for (int i = 0; i < V.Num(); i++) C.Add(FLinearColor(0.8f, 0.8f, 0.8f, 1));
		PostsMesh.UpdateMeshSection_LinearColor(0, V, N, UV,
			TArray<FVector2D>(), TArray<FVector2D>(), TArray<FVector2D>(),
			C, Tan, false);
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
}
