// Sand burst FX: sprays grains UP and outward on impacts and footsteps.
//
// Procedural CPU particle pool rendered as camera-facing quads (asset-free).
// Niagara systems can be assigned for GPU sand; the actual spawn call is wired
// once the base scripts are confirmed compiling against this engine (see Burst).

class ASandFX : AActor
{
	UPROPERTY(DefaultComponent, RootComponent)
	UProceduralMeshComponent DustMesh;

	// Optional Niagara systems (author in editor, then assign on the actor).
	UPROPERTY()
	UNiagaraSystem ImpactSystem;

	UPROPERTY()
	UNiagaraSystem FootstepSystem;

	// --- CPU particle pool ---
	// Raised 260 -> 400 (Erik, 2026-09-06: "mycket om billigt" — a lot, if
	// it's cheap — turning sand spray back on for light graphics). It is:
	// camera-facing quads with per-vertex colour, no material lookups beyond
	// BasicShapeMaterial, same cost per particle live gameplay already pays
	// in normal mode. 400 floats/vectors is a few KB, not a frame-time line.
	const int   MaxParticles = 400;
	const float PGravity     = -980.0f;
	const float PDrag        = 0.6f;
	const float GroundZ      = 0.0f;

	private TArray<FVector> PPos;
	private TArray<FVector> PVel;
	private TArray<float>   PLife;     // remaining seconds
	private TArray<float>   PLifeMax;
	private TArray<float>   PSize;
	private int NextFree = 0;
	private bool bDustDirty = false;

	// DustMesh had no material at all before this (2026-09-06) — CreateMeshSection_
	// LinearColor's per-vertex colours went nowhere: the engine's own default
	// material does not read them, the same "renders as the flat default,
	// not what the vertex data says" trap CLAUDE.md documents for a missing
	// usage flag. Every OTHER coloured element in this codebase (Ball, Court,
	// TeamRing, the player tint, both ShadowBlobs) carries its colour on a
	// BasicShapeMaterial "Color" PARAMETER instead of vertex colour, for
	// exactly this reason — DustMesh now matches. Per-vertex colour stays in
	// RebuildDust as plain white; the parameter below is the only thing that
	// actually tints it, which costs the old per-particle life-fade tint
	// (still fades in SIZE, via PSize's own frac term).
	private UMaterialInstanceDynamic DustMID;

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		UMaterialInterface Base = Cast<UMaterialInterface>(LoadObject(nullptr,
			"/Engine/BasicShapes/BasicShapeMaterial.BasicShapeMaterial"));
		if (Base != nullptr)
		{
			DustMID = DustMesh.CreateDynamicMaterialInstance(0, Base);
			if (DustMID != nullptr)
				DustMID.SetVectorParameterValue(n"Color", FLinearColor(0.95f, 0.86f, 0.66f, 1));
		}

		for (int i = 0; i < MaxParticles; i++)
		{
			PPos.Add(FVector::ZeroVector);
			PVel.Add(FVector::ZeroVector);
			PLife.Add(0.0f);
			PLifeMax.Add(1.0f);
			PSize.Add(2.0f);
		}
	}

	// --- Light graphics mode (toggled with B — see ABeachVolleyballGameMode) ----
	// The sand is gone, but the spray stays ON now (Erik, 2026-09-06) — no
	// ground to kick it up FROM is not a reason to also cut a burst that
	// reads perfectly well against a plain sky, and it is one more motion
	// cue in a mode that exists to make motion easy to read. RebuildDust
	// tints it pink here instead of the normal sandy tan, matching the
	// mode's own strong flat team colours rather than trying to fake a sand
	// colour with no sand mesh left to match against.
	private bool bLightGraphics = false;

	void SetLightGraphics(bool bOn)
	{
		bLightGraphics = bOn;
		if (DustMID != nullptr)
		{
			DustMID.SetVectorParameterValue(n"Color", bOn
				? FLinearColor(1.00f, 0.30f, 0.65f, 1)
				: FLinearColor(0.95f, 0.86f, 0.66f, 1));
		}
	}

	// Strong upward sand spray from a ball impact.
	UFUNCTION(BlueprintCallable)
	void Burst(FVector Pos, FVector ImpactVel, float Strength)
	{
		float S = Math::Clamp(Strength, 0.1f, 3.0f);

		// NOTE: When ImpactSystem is assigned, spawn it here once the Niagara
		// AngelScript namespace is confirmed, e.g.:
		//   Niagara::SpawnSystemAtLocation(ImpactSystem, Pos, FRotator::ZeroRotator);
		// Until then (and whenever no system is set) the procedural spray runs.

		// Light graphics gets a bigger burst on purpose ("mycket om billigt"):
		// the same cheap quad pool, just more of it, since nothing else is
		// competing for this mode's frame time the way the full beach does.
		int Count = int(18.0f + S * 34.0f);
		if (bLightGraphics) Count = int(Count * 1.6f);
		SprayFallback(Pos, ImpactVel, S, Count, 1.0f);
	}

	// Smaller puff kicked up under a footstep.
	UFUNCTION(BlueprintCallable)
	void Footstep(FVector Pos, float Strength)
	{
		float S = Math::Clamp(Strength, 0.1f, 2.0f);

		if (FootstepSystem != nullptr)
		{
			Niagara::SpawnSystemAtLocation(FootstepSystem, Pos, FRotator::ZeroRotator);
			return;
		}

		int Count = int(6.0f + S * 10.0f);
		if (bLightGraphics) Count = int(Count * 1.6f);
		SprayFallback(Pos, FVector(0, 0, 0), S, Count, 0.5f);
	}

	// Emit Count grains with a strong vertical component.
	private void SprayFallback(FVector Pos, FVector ImpactVel, float Strength,
		int Count, float Scale)
	{
		FVector HBias = FVector(-ImpactVel.X, -ImpactVel.Y, 0).GetSafeNormal();

		for (int n = 0; n < Count; n++)
		{
			int idx = NextFree;
			NextFree = (NextFree + 1) % MaxParticles;

			float ang = Math::RandRange(0.0f, 2.0f * PI);
			float radial = Math::RandRange(0.2f, 1.0f);
			FVector OutDir = FVector(Math::Cos(ang), Math::Sin(ang), 0) * radial
				+ HBias * 0.6f;

			float hSpeed = Math::RandRange(60.0f, 220.0f) * Strength * Scale;
			float upSpeed = Math::RandRange(220.0f, 520.0f) * Strength * Scale;

			PPos[idx] = Pos + FVector(0, 0, 2);
			PVel[idx] = OutDir.GetSafeNormal() * hSpeed + FVector(0, 0, upSpeed);
			float life = Math::RandRange(0.45f, 0.95f);
			PLife[idx] = life;
			PLifeMax[idx] = life;
			PSize[idx] = Math::RandRange(1.5f, 4.0f) * (0.7f + Strength * 0.3f);
		}
		bDustDirty = true;
	}

	UFUNCTION(BlueprintOverride)
	void Tick(float DeltaTime)
	{
		bool bAnyAlive = false;
		float damp = 1.0f - Math::Clamp(PDrag * DeltaTime, 0.0f, 1.0f);

		for (int i = 0; i < MaxParticles; i++)
		{
			if (PLife[i] <= 0.0f) continue;
			bAnyAlive = true;

			PVel[i].Z += PGravity * DeltaTime;
			PVel[i] *= damp;
			PPos[i] += PVel[i] * DeltaTime;

			if (PPos[i].Z <= GroundZ)
			{
				PPos[i].Z = GroundZ;
				PVel[i] = FVector::ZeroVector;
				PLife[i] = Math::Min(PLife[i], 0.12f);
			}

			PLife[i] -= DeltaTime;
		}

		if (bAnyAlive || bDustDirty)
		{
			bDustDirty = false;
			RebuildDust();
		}
	}

	// Render alive grains as small quads facing the side camera (-Y).
	private void RebuildDust()
	{
		TArray<FVector> V;
		TArray<int32> T;
		TArray<FVector> N;
		TArray<FVector2D> UV;
		TArray<FLinearColor> C;
		TArray<FVector2D> NoUV;
		TArray<FProcMeshTangent> Tan;

		for (int i = 0; i < MaxParticles; i++)
		{
			if (PLife[i] <= 0.0f) continue;

			float frac = PLife[i] / PLifeMax[i];
			float s = PSize[i] * (0.4f + 0.6f * frac);
			FVector P = PPos[i];
			int b = V.Num();

			V.Add(P + FVector(-s, 0, -s));
			V.Add(P + FVector( s, 0, -s));
			V.Add(P + FVector( s, 0,  s));
			V.Add(P + FVector(-s, 0,  s));

			for (int k = 0; k < 4; k++) N.Add(FVector(0, -1, 0));
			UV.Add(FVector2D(0, 0)); UV.Add(FVector2D(1, 0));
			UV.Add(FVector2D(1, 1)); UV.Add(FVector2D(0, 1));

			// Plain white — DustMID's own Color parameter (see BeginPlay/
			// SetLightGraphics) is what actually tints these now, not vertex
			// colour (see that field's comment for why). The old per-particle
			// life-fade tint is gone; PSize's own frac shrink still fades it.
			for (int k = 0; k < 4; k++)
				C.Add(FLinearColor(1, 1, 1, 1));

			T.Add(b); T.Add(b + 2); T.Add(b + 1);
			T.Add(b); T.Add(b + 3); T.Add(b + 2);
		}

		if (V.Num() == 0)
		{
			DustMesh.ClearMeshSection(0);
			return;
		}

		DustMesh.CreateMeshSection_LinearColor(0, V, T, N, UV,
			TArray<FVector2D>(), TArray<FVector2D>(), TArray<FVector2D>(),
			C, Tan, false, false);
	}
}
