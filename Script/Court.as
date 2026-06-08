// Beach volleyball court - sand, net, lines, posts via ProceduralMeshComponent

class ACourt : AActor
{
	UPROPERTY()
	UProceduralMeshComponent SandMesh;

	UPROPERTY()
	UProceduralMeshComponent NetMesh;

	UPROPERTY()
	UProceduralMeshComponent LinesMesh;

	UPROPERTY()
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

	void BeginPlay() override
	{
		Super::BeginPlay();
		BuildSand();
		BuildNet();
		BuildLines();
		BuildPosts();
	}

	// Flat sand quad
	private void BuildSand()
	{
		TArray<FVector> V;
		TArray<int32> T;
		TArray<FVector> N;
		TArray<FVector2D> UV;
		TArray<FProcMeshTangent> Tan;

		float W = CourtHalfLength + 200.0f; // extra sand border
		float D = CourtHalfWidth + 200.0f;

		V.Add(FVector(-W, -D, 0));
		V.Add(FVector( W, -D, 0));
		V.Add(FVector( W,  D, 0));
		V.Add(FVector(-W,  D, 0));

		T.Add(0); T.Add(2); T.Add(1);
		T.Add(0); T.Add(3); T.Add(2);

		for (int i = 0; i < 4; i++) N.Add(FVector(0,0,1));
		UV.Add(FVector2D(0,0));
		UV.Add(FVector2D(1,0));
		UV.Add(FVector2D(1,1));
		UV.Add(FVector2D(0,1));

		SandMesh.CreateMeshSection_LinearColor(0, V, T, N, UV,
			TArray<FLinearColor>(), Tan, true);

		// Sandy color
		TArray<FLinearColor> C;
		for (int i = 0; i < 4; i++) C.Add(FLinearColor(0.93f, 0.83f, 0.60f, 1));
		SandMesh.UpdateMeshSection_LinearColor(0, V, N, UV, C, Tan);
	}

	// Net: flat quad with dark color
	private void BuildNet()
	{
		TArray<FVector> V;
		TArray<int32> T;
		TArray<FVector> N;
		TArray<FVector2D> UV;
		TArray<FProcMeshTangent> Tan;

		float HW = CourtHalfWidth + 30.0f; // net slightly wider than court

		V.Add(FVector(-NetHalfThick, -HW, 0));
		V.Add(FVector( NetHalfThick, -HW, 0));
		V.Add(FVector( NetHalfThick,  HW, 0));
		V.Add(FVector(-NetHalfThick,  HW, 0));

		V.Add(FVector(-NetHalfThick, -HW, NetHeight));
		V.Add(FVector( NetHalfThick, -HW, NetHeight));
		V.Add(FVector( NetHalfThick,  HW, NetHeight));
		V.Add(FVector(-NetHalfThick,  HW, NetHeight));

		// Front face
		T.Add(0); T.Add(1); T.Add(5); T.Add(0); T.Add(5); T.Add(4);
		// Back face
		T.Add(2); T.Add(3); T.Add(7); T.Add(2); T.Add(7); T.Add(6);
		// Top
		T.Add(4); T.Add(5); T.Add(6); T.Add(4); T.Add(6); T.Add(7);

		for (int i = 0; i < 8; i++) N.Add(FVector(0,0,1));
		for (int i = 0; i < 8; i++) UV.Add(FVector2D(0,0));

		NetMesh.CreateMeshSection_LinearColor(0, V, T, N, UV,
			TArray<FLinearColor>(), Tan, false);

		TArray<FLinearColor> C;
		for (int i = 0; i < 8; i++) C.Add(FLinearColor(0.1f, 0.1f, 0.1f, 0.85f));
		NetMesh.UpdateMeshSection_LinearColor(0, V, N, UV, C, Tan);
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
			TArray<FLinearColor>(), Tan, false);

		TArray<FLinearColor> C;
		for (int i = 0; i < V.Num(); i++) C.Add(FLinearColor(1,1,1,1));
		LinesMesh.UpdateMeshSection_LinearColor(0, V, N, UV, C, Tan);
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
			TArray<FLinearColor>(), Tan, false);

		TArray<FLinearColor> C;
		for (int i = 0; i < V.Num(); i++) C.Add(FLinearColor(0.8f, 0.8f, 0.8f, 1));
		PostsMesh.UpdateMeshSection_LinearColor(0, V, N, UV, C, Tan);
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
