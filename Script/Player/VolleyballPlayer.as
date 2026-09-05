// Base player pawn — movement, jump, physical ball contact, IK targets,
// and skeletal (Manny) body. Drives UVolleyballAnimInstance (see PlayerAnim.as).

class AVolleyballPlayer : APawn
{
	UPROPERTY(DefaultComponent, RootComponent)
	UCapsuleComponent Capsule;

	UPROPERTY(DefaultComponent, Attach = Capsule)
	USkeletalMeshComponent Mesh;

	// Team identity, as a ring drawn on the sand under the player.
	//
	// It is a ring and not a coloured jersey because the body isn't just untinted
	// on Android, it's unlit — pure (0,0,0) at the torso in a device screenshot,
	// while the sky/sand next to it are lit correctly (see ApplyTeamMaterial).
	// Rather than keep guessing inside a material that cannot be opened here, put
	// the team colour on geometry we control, using the same procedural mesh +
	// BasicShapeMaterial path that already works for the court, the net and the
	// sky.
	UPROPERTY(DefaultComponent, Attach = Capsule)
	UProceduralMeshComponent TeamRing;

	// The ring is built once at construction, so editing TeamRingColor() would not show
	// up on players that already exist — hot reload swaps code, it does not re-run
	// construction. Holding the material instance and the colour last pushed to it lets
	// UpdatePlayer notice a changed return value and repaint, so colour edits are live.
	UMaterialInstanceDynamic RingMID;
	FLinearColor AppliedRingColor = FLinearColor(-1, -1, -1, -1);

	float MoveSpeed = 450.0f;
	// PLAYER gravity is ~2x earth (the ball keeps real -980): with real g the
	// tuned jump heights hung airborne ~1.5s and read as moon-floating. Heavy
	// player gravity + scaled jump speeds is the standard trick for snappy,
	// athletic jumps — rise ~70cm reactive / ~115cm loaded, air time ~0.7s.
	float JumpVelocity = 520.0f;
	float Gravity = -1900.0f;

	FVector PlayerVelocity = FVector::ZeroVector;
	bool bIsGrounded = true;
	float FloorZ = 0.0f;
	float PlayerHeight = 90.0f;

	// Single source of truth for body facing. AI/look code sets a desired facing
	// direction (flat); UpdatePlayer smoothly turns the actor toward it ONCE per
	// frame. This avoids multiple SetActorRotation callers fighting each other,
	// which caused jerky spinning (especially around jumps).
	FVector FacingDir = FVector(1, 0, 0);
	bool bHasFacing = false;
	private float FacingHoldTimer = 0.0f;   // facing requests lapse on this
	// Rate-limited FacingDir: the raw target the AI recomputes wholesale every
	// reaction tick (a close/fast ball can swing its bearing through a wide
	// angle in one tick); this is what the rotation and turn-run alignment
	// actually track, so the body is never asked to reverse turn direction
	// instantaneously when the raw target crosses to the other side.
	private FVector SmFacingDir = FVector(1, 0, 0);
	const float FacingDirMaxTurnRate = 300.0f;   // deg/s — limits the TARGET
	// Ceiling on how fast the BODY itself may rotate (deg/s). Distinct from the
	// above, which only ever limited where the body was aiming. Measured peak
	// before this existed: 1239 deg/s, median 566.
	const float BodyMaxTurnRate = 450.0f;
	// The one rate-limited facing target that all three sources feed through.
	private FVector SmWantDir;
	// Committed turn direction (signed degrees, last frame's Delta) — breaks
	// the near-180° shortest-path tie deterministically instead of by float
	// noise. See the rotation block in UpdatePlayer.
	private float RotDirBias = 0.0f;

	ETeam TeamSide = ETeam::Team_A;
	bool bCanHit = true;
	float HitCooldown = 0.4f;
	float HitTimer = 0.0f;

	float CourtMinX = -900.0f;
	float CourtMaxX = -5.0f;
	float CourtMinY = -450.0f;
	float CourtMaxY = 450.0f;

	UPROPERTY() ASandFX Sand;
	UPROPERTY() ACourt Court;
	UPROPERTY() ABeachVolleyballGameMode GM;

	private float StepTimer = 0.0f;
	private float ReachTimer = 0.0f;
	private FVector ReachDir = FVector(0, 0, 1);

	// Animation: we write state into this each frame; the Anim Blueprint blends.
	// Anim and CurrentHit are public so the IK mixin module (PlayerIK.as) can read
	// the current hit type and write the computed effector targets into the AnimInstance.
	UVolleyballAnimInstance Anim;
	EHitType CurrentHit = EHitType::Hit_None;
	private float HitAnimTimer = 0.0f;
	private float HitAnimDuration = 0.65f;  // hit pose swings up and back over this time

	void InitPlayer()
	{
		FloorZ = 0.0f;
		SetupMesh();
	}

	private void SetupMesh()
	{
		if (Mesh == nullptr) return;

		// Use SKM_Manny_Simple (the renderable SkeletalMesh) copied into the project.
		// NOTE: SK_Mannequin is the *Skeleton* asset, not a mesh — don't load that.
		// All bundled template anim clips reference this skeleton, so they play
		// without retargeting.
		USkeletalMesh SkMesh = Cast<USkeletalMesh>(LoadObject(nullptr,
			"/Game/Characters/Mannequins/Meshes/SKM_Manny_Simple.SKM_Manny_Simple"));
		if (SkMesh == nullptr)
		{
			// The local template copy originated in UE 5.6. On a strict mobile
			// loader it can fail before its packages have been re-saved in 5.8.
			// MoverExamples is enabled for this project and supplies the matching,
			// current-engine Manny mesh as a safe runtime fallback.
			//
			// Verified 2026-08-02 that Android does NOT take this path — removing it
			// entirely changed nothing on device, so the /Game mesh does load there.
			// Worth knowing if this is ever suspected again: under match lighting this
			// fallback mesh renders near-black (torso (2,1,0) vs (68,44,26)), so if it
			// ever DOES get taken it looks like a bug in its own right.
			Log("VolleyballPlayer: project Manny mesh unavailable; trying MoverExamples copy");
			SkMesh = Cast<USkeletalMesh>(LoadObject(nullptr,
				"/MoverExamples/Characters/Mannequins/Meshes/SKM_Manny_Simple.SKM_Manny_Simple"));
		}
		if (SkMesh == nullptr)
		{
			// Content not found — keep player visible with a fallback box
			Log("VolleyballPlayer: both Manny mesh load paths failed; using fallback box");
			Print("VolleyballPlayer: Manny mesh failed to load, using fallback box", Duration = 8.0f);
			SpawnFallbackBox();
			return;
		}

		Mesh.SkeletalMeshAsset = SkMesh;

		// Stand the mesh on the capsule floor and face along +X
		Mesh.SetRelativeLocation(FVector(0, 0, -PlayerHeight));
		Mesh.SetRelativeRotation(FRotator(0, -90, 0));

		// Use a blended Animation Blueprint when available (preferred — gives
		// idle/walk/run blendspace + jump/fall + bump/set/spike montages), and
		// fall back to the raw Angelscript anim instance otherwise so the game
		// still runs before the Anim BP is authored in the editor.
		Mesh.SetAnimationMode(EAnimationMode::AnimationBlueprint);

		UClass AnimBP = Cast<UClass>(LoadObject(nullptr,
			"/Game/Characters/Mannequin/ABP_VolleyballPlayer.ABP_VolleyballPlayer_C"));
		if (AnimBP != nullptr)
			Mesh.SetAnimInstanceClass(AnimBP);
		else
			Mesh.SetAnimInstanceClass(UVolleyballAnimInstance);

		Anim = Cast<UVolleyballAnimInstance>(Mesh.GetAnimInstance());

		// Mesh/ABP binding, logged once per player. Worth keeping: the ABP is
		// authored against /MoverExamples/.../SK_Mannequin while this mesh
		// references /Game/Characters/Mannequins/Meshes/SK_Mannequin — two
		// DIFFERENT skeleton assets. That binding does work (89 bones, ABP
		// attached, verified in a headless run), so it is not itself a bug, but
		// it means every locomotion clip is retargeted across skeletons and this
		// line is the first thing to check if the pose ever looks wrong.
		Log("MESHSKEL mesh=" + SkMesh.GetPathName()
			+ " bones=" + Mesh.GetNumBones()
			+ " animBP=" + (AnimBP != nullptr ? "yes" : "NO"));

		// Tint per-team via the body material's vertex/param if available
		ApplyTeamMaterial();
		BuildTeamRing();
		SetupRagdollPhysics();
	}

	// PA_Mannequin gives real body collision for dive slides. The asset lives in
	// Content/Characters/Mannequins/Rigs/ (not referenced anywhere else yet).
	bool bRagdollReady = false;
	UPROPERTY()
	UPhysicsAsset RagdollPhysAsset;

	// THE PHYSICS ASSET IS BORROWED FOR THE SLIDE AND HANDED BACK.
	//
	// It used to be applied to every player at BeginPlay and left on for the
	// whole match, so a player who never dived paid for it anyway. Measured by
	// removing this one call and changing nothing else: spike-approach gather
	// went from 0 back to 12 m/s^2, jumps from NONE ACROSS 135 RALLIES back to
	// 85cm, ball contacts from 0.77 to 1.03 per rally. The attack game was gone.
	//
	// The reason is that a skeletal mesh with a physics asset resolves its bones
	// through the physics bodies, so Mesh.GetBoneTransform stops meaning "where
	// the animation put this bone". That read is load-bearing across this whole
	// project: GetArmContact tests the ball against the forearm bones, and every
	// IK anchor in PlayerIK.as is a bone read. Degrade it and players can no
	// longer touch the ball, which is the game.
	//
	// Gating SetEnablePhysicsBlending alone was tried first and did NOT help —
	// it is the asset, not the blend flag. So the asset is applied in
	// StartRagdollSlide and cleared in EndRagdollSlide: the mesh is in its
	// ordinary animated state for the entire match except the half second a body
	// is actually sliding on the sand.
	//
	// (One number that looked like a free win was also an artifact of this:
	// `bob` reading 13cm instead of 55 while the asset was on was the pelvis read
	// changing under the metric, not the hips settling.)
	private void SetupRagdollPhysics()
	{
		if (Mesh == nullptr) return;

		RagdollPhysAsset = Cast<UPhysicsAsset>(LoadObject(nullptr,
			"/Game/Characters/Mannequins/Rigs/PA_Mannequin.PA_Mannequin"));
		if (RagdollPhysAsset == nullptr)
		{
			RagdollPhysAsset = Cast<UPhysicsAsset>(LoadObject(nullptr,
				"/MoverExamples/Characters/Mannequins/Rigs/PA_Mannequin.PA_Mannequin"));
		}
		if (RagdollPhysAsset == nullptr)
		{
			Log("VolleyballPlayer: PA_Mannequin unavailable — dive ragdoll disabled");
			return;
		}

		// Cached only. Nothing is applied to the mesh until a dive lands.
		Mesh.SetCollisionEnabled(ECollisionEnabled::NoCollision);
		bRagdollReady = true;
	}

	// Flat annulus on the sand in the player's team colour.
	private void BuildTeamRing()
	{
		const int Segs = 24;
		const float RInner = 42.0f;
		const float ROuter = 58.0f;

		TArray<FVector> V; TArray<int32> T; TArray<FVector> N;
		TArray<FVector2D> UV; TArray<FLinearColor> C;
		TArray<FVector2D> NoUV; TArray<FProcMeshTangent> Tan;

		for (int i = 0; i < Segs; i++)
		{
			float A = 2.0f * PI * i / Segs;
			float Cx = Math::Cos(A);
			float Sy = Math::Sin(A);
			V.Add(FVector(Cx * RInner, Sy * RInner, 0));
			V.Add(FVector(Cx * ROuter, Sy * ROuter, 0));
		}

		for (int i = 0; i < Segs; i++)
		{
			int A0 = i * 2;
			int B0 = ((i + 1) % Segs) * 2;
			T.Add(A0); T.Add(B0);     T.Add(B0 + 1);
			T.Add(A0); T.Add(B0 + 1); T.Add(A0 + 1);
			// Reverse winding as well, so it reads from above whichever way the
			// front face ends up pointing.
			T.Add(A0); T.Add(B0 + 1); T.Add(B0);
			T.Add(A0); T.Add(A0 + 1); T.Add(B0 + 1);
		}

		FLinearColor Col = TeamRingColor();
		for (int i = 0; i < V.Num(); i++)
		{
			N.Add(FVector(0, 0, 1));
			UV.Add(FVector2D(0, 0));
			C.Add(Col);
		}

		TeamRing.CreateMeshSection_LinearColor(0, V, T, N, UV, NoUV, NoUV, NoUV, C, Tan, false);
		TeamRing.SetCastShadow(false);

		// Same helper as ACourt/AEnvironment, copied rather than shared: this fork
		// compiles each .as file as its own module, so a global function is only
		// visible inside its own file.
		UMaterialInterface Base = Cast<UMaterialInterface>(LoadObject(nullptr,
			"/Engine/BasicShapes/BasicShapeMaterial.BasicShapeMaterial"));
		if (Base != nullptr)
		{
			RingMID = TeamRing.CreateDynamicMaterialInstance(0, Base);
			if (RingMID != nullptr)
			{
				RingMID.SetVectorParameterValue(n"Color", Col);
				AppliedRingColor = Col;
			}
		}
	}

	// Repaint the ring when TeamRingColor() starts returning something else, which is
	// what makes a hot-reloaded colour edit visible on players that are already on court.
	private void RefreshTeamRingColor()
	{
		if (RingMID == nullptr)
			return;

		FLinearColor Want = TeamRingColor();
		if (Want.R == AppliedRingColor.R && Want.G == AppliedRingColor.G
			&& Want.B == AppliedRingColor.B && Want.A == AppliedRingColor.A)
			return;

		RingMID.SetVectorParameterValue(n"Color", Want);
		AppliedRingColor = Want;
	}

	// Pre-divided by the measured per-channel light gain (0.314,0.162,0.067) — see
	// the long note in Environment.as. Blue reaches the screen at 21% of red under
	// this sunset, so an honest blue would read as grey; 3.0 in the blue channel is
	// what it costs to actually look blue. Red is lifted too, but less, since it
	// needs no help getting through.
	private FLinearColor TeamRingColor() const
	{
		return (TeamSide == ETeam::Team_A)
			? FLinearColor(0.10f, 0.60f, 3.00f, 1)
			: FLinearColor(1.60f, 0.25f, 0.15f, 1);
	}

	// Visible placeholder so a player is never invisible if the mesh can't load
	private void SpawnFallbackBox()
	{
		UStaticMeshComponent Box = UStaticMeshComponent::Create(this);
		Box.AttachToComponent(Capsule);
		UStaticMesh Cube = Cast<UStaticMesh>(LoadObject(nullptr,
			"/Engine/BasicShapes/Cube.Cube"));
		if (Cube != nullptr)
		{
			Box.SetStaticMesh(Cube);
			Box.SetRelativeScale3D(FVector(0.4f, 0.6f, 1.7f));
			Box.SetRelativeLocation(FVector(0, 0, 0));
			UMaterialInterface BaseMat = Box.GetMaterial(0);
			if (BaseMat != nullptr)
			{
				UMaterialInstanceDynamic MID = Box.CreateDynamicMaterialInstance(0, BaseMat);
				if (MID != nullptr)
					MID.SetVectorParameterValue(n"Color", TeamColor());
			}
		}
	}

	private void ApplyTeamMaterial()
	{
		if (Mesh == nullptr) return;

		// Keep the mesh's OWN imported materials (MI_Manny_01/02_New) and only tint
		// them. They were suspected for a long time of being broken on Android —
		// several builds replaced them with the engine DefaultMaterial, and one with
		// a custom mobile-safe material authored just for this. None of that was
		// necessary: measured on device, a trivial custom material and the stock one
		// land within noise of each other (body max (121,82,46) vs (114,82,53)). The
		// bodies were black because almost no light reached the side of them the
		// camera sees — see the sun-aiming note in GameMode.as::SetupWorld.
		//
		// THE TINT PARAMETER IS NAMED DIFFERENTLY ON THE TWO MESHES, so set both.
		// Names read off the assets, not guessed:
		//   /Game .../MI_Manny_01_New  -> "Paint Tint" (with the space)
		//   /MoverExamples .../MI_Manny_01 -> "Tint"
		// SetupMesh() prefers the /Game mesh and falls back to the MoverExamples
		// one, and CI only ever has the fallback (Content/Characters/ is mostly
		// gitignored for the LFS budget). Setting a parameter that does not exist
		// is a silent no-op rather than an error, so for a long time this set
		// "Paint Tint" on a material that only has "Tint" and the bodies shipped
		// untinted — the same silent-miss the two earlier wrong names caused.
		// Setting both is harmless: each mesh ignores the name it does not have.
		ApplyBodyTint(TeamBodyTint());
	}

	// The tinting loop itself, so light graphics mode can reuse it with a colour
	// of its own instead of re-implementing the two-parameter-names dance above.
	private void ApplyBodyTint(FLinearColor Tint)
	{
		if (Mesh == nullptr) return;

		int NumSlots = Mesh.GetNumMaterials();
		for (int i = 0; i < NumSlots; i++)
		{
			UMaterialInterface SlotMat = Mesh.GetMaterial(i);
			if (SlotMat == nullptr) continue;

			UMaterialInstanceDynamic MID = Mesh.CreateDynamicMaterialInstance(i, SlotMat);
			if (MID != nullptr)
			{
				MID.SetVectorParameterValue(n"Paint Tint", Tint);
				MID.SetVectorParameterValue(n"Tint", Tint);
			}
		}
	}

	// --- Light graphics mode (toggled with B — see ABeachVolleyballGameMode) ----
	//
	// The body keeps its own material and gets a strong flat team tint, and it
	// stops casting shadows. That is all the mode does to a player.
	//
	// IT USED TO TRY FOR MORE, AND THE MORE NEVER RENDERED. The first version
	// swapped every slot for /Engine/BasicShapes/BasicShapeMaterial at roughness
	// 0.05 — a mirror shell, "the player's reflection layer" — and in the editor
	// that looked right, because the editor quietly sets a material's usage flags
	// for you when you assign it. In a real -game run the log says:
	//
	//   Material /Engine/BasicShapes/BasicShapeMaterial missing usage flag
	//   SkeletalMesh! Default Material will be used in game.
	//
	// So the shells were the engine's default material all along: four black
	// cutouts, unmoved by any base colour, roughness or light we threw at them —
	// which is exactly how it filmed. BasicShapeMaterial is fine on TeamRing and
	// the court because those are procedural/static meshes; a SKELETAL mesh needs
	// bUsedWithSkeletalMesh, and nothing in script can set that flag.
	//
	// Getting the mirror look back means authoring a material asset with that flag
	// ticked — and Content/*.uasset is deliberately outside git (see CLAUDE.md), so
	// such an asset would be missing on a fresh clone and in CI, i.e. the mode would
	// silently fall back to black again on exactly the machines nobody is watching.
	// A tint on the material the mesh already ships with cannot fail that way.
	//
	// Restoring does NOT keep the old MIDs around: ApplyTeamMaterial() re-creates
	// them from the slots' own materials, the same path startup takes.
	private bool bLightGraphics = false;

	void SetLightGraphics(bool bOn)
	{
		if (Mesh == nullptr || bOn == bLightGraphics) return;

		if (bOn)
			ApplyBodyTint(LightModeTint());
		else
			ApplyTeamMaterial();

		Mesh.SetCastShadow(!bOn);
		bLightGraphics = bOn;
	}

	// Far stronger than TeamBodyTint(): this is a multiply over the body texture,
	// and in light graphics the point is to tell two bodies apart instantly with a
	// beach that is no longer there to give them context. Blue and orange rather
	// than blue and red — red goes muddy against the sand-free grey-blue ground.
	// Values above ~2 blow the texture out to a flat silhouette, which is the
	// failure this whole mode keeps circling back to; do not raise them further.
	private FLinearColor LightModeTint() const
	{
		return (TeamSide == ETeam::Team_A)
			? FLinearColor(0.30f, 0.75f, 1.90f, 1)
			: FLinearColor(1.90f, 0.70f, 0.18f, 1);
	}

	// Kept close to the material's own default (0.92 grey) on purpose. "Paint Tint"
	// MULTIPLIES the body texture, so the HDR values TeamColor() uses would crush or
	// blow out the texture and hand back the flat silhouette this whole exercise was
	// about. Team identity is carried by TeamRing on the sand; this is only a hint.
	private FLinearColor TeamBodyTint() const
	{
		return (TeamSide == ETeam::Team_A)
			? FLinearColor(0.74f, 0.88f, 1.06f, 1)
			: FLinearColor(1.06f, 0.84f, 0.76f, 1);
	}

	void UpdatePlayer(float DeltaTime)
	{
		// Pin the team ring to the sand. It hangs off the capsule so it follows the
		// player around, but the capsule also rises on a jump, and a marker ring
		// floating at head height would read as a bug rather than as a shadow.
		// Cancelling the actor's Z keeps it flat on the beach at all times.
		TeamRing.SetRelativeLocation(FVector(0, 0, 2.0f - GetActorLocation().Z));
		RefreshTeamRingColor();

		// Crouch release runs FIRST, before any writer: with the decay at the
		// end of the frame it subtracted from what dive/tuck/split-step had
		// just asserted and ExtraCrouch sawtoothed ±0.04 at frame rate — the
		// universal residual the jitter monitor kept catching. Decay first,
		// writers last, the final value each frame is the writer's.
		//
		// TWO CHANNELS with different lifetimes (see the declarations):
		//  - ExtraCrouch (frame-rate transients: split step, dive, jump load,
		//    land absorb, air tuck) decays EVERY frame. Its writers run every
		//    frame while active, so decay-then-rewrite reproduces the envelope
		//    exactly and the value falls the instant the envelope stops.
		//  - HeldCrouch (tick-rate AI stance via RequestCrouch) is HELD across
		//    the reaction-tick gap and only decays once the hold lapses.
		// The old single channel gave the transients the HELD lifetime too: a
		// split-step peak Max()-ed in while a stance hold was live could not
		// decay until the hold gap — and the gaps land on ball events — so the
		// knee stuck deep through the approach and popped up at the meet. The
		// two are re-combined by Max at the read site, so the deepest legitimate
		// request still wins; only the STUCK residual is gone.
		ExtraCrouch = Math::Max(0.0f, ExtraCrouch - 2.5f * DeltaTime);
		CrouchHoldTimer -= DeltaTime;
		if (CrouchHoldTimer <= 0.0f)
			HeldCrouch = Math::Max(0.0f, HeldCrouch - 2.5f * DeltaTime);

		// Dive overrides input; otherwise ease velocity toward the stored input.
		UpdateDive(DeltaTime);
		UpdateJumpLoad(DeltaTime);
		if (!IsDiving() && !bRagdollActive)
			ApplyMoveInput(DeltaTime);

		// Gravity
		if (!bIsGrounded)
			PlayerVelocity.Z += Gravity * DeltaTime;

		bool bWasGrounded = bIsGrounded;
		float FallSpeed = -PlayerVelocity.Z;

		// ONE integration path, ragdoll slide included. The slide used to get its
		// own branch that skipped the court clamp below and set the location
		// straight from the simulated pelvis — so a dive near the sideline slid
		// the player out of the court, and the pelvis's per-frame wobble became
		// the capsule's motion. The slide is now an ordinary deceleration
		// (UpdateRagdollSlide) travelling through exactly these clamps.
		FVector NewLoc = GetActorLocation() + PlayerVelocity * DeltaTime;

		// Floor clamp
		if (NewLoc.Z <= FloorZ + PlayerHeight)
		{
			NewLoc.Z = FloorZ + PlayerHeight;
			PlayerVelocity.Z = 0;
			bIsGrounded = true;
		}

		// Court bounds
		NewLoc.X = Math::Clamp(NewLoc.X, CourtMinX, CourtMaxX);
		NewLoc.Y = Math::Clamp(NewLoc.Y, CourtMinY, CourtMaxY);

		SetActorLocation(NewLoc);

		// Sand FX + landing absorption: knees flex on touchdown, deeper after a
		// bigger fall — a stiff-legged landing is both unphysical and unreadable.
		FVector ActorLoc = GetActorLocation();
		FVector Feet = FVector(ActorLoc.X, ActorLoc.Y, 0.0f);
		if (bIsGrounded && !bWasGrounded && FallSpeed > 120.0f)
		{
			float Strength = Math::Clamp(FallSpeed / 600.0f, 0.3f, 1.6f);
			if (Sand != nullptr) Sand.Footstep(Feet, Strength * 1.4f);
			if (Court != nullptr) Court.DeformSand(Feet, 24.0f, 4.0f + Strength * 6.0f);
			LandAbsorbTimer = 0.3f;
			LandAbsorbDepth = Math::Clamp(FallSpeed / 900.0f, 0.3f, 0.7f);
		}
		if (LandAbsorbTimer > 0.0f)
		{
			LandAbsorbTimer -= DeltaTime;
			ExtraCrouch = Math::Max(ExtraCrouch, LandAbsorbDepth * (LandAbsorbTimer / 0.3f));
		}

		// Airborne attack tuck: knees come up through the ascent of a spike or
		// block jump (release on the way down) — legs trail dead otherwise.
		if (!bIsGrounded && PlayerVelocity.Z > -100.0f
			&& (CurrentHit == EHitType::Hit_Spike || CurrentHit == EHitType::Hit_Block))
		{
			ExtraCrouch = Math::Max(ExtraCrouch, 0.35f);
		}
		if (bIsGrounded)
		{
			float HSpeed = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0).Size();
			if (HSpeed > 80.0f)
			{
				StepTimer += DeltaTime;
				float Interval = Math::Clamp(120.0f / HSpeed, 0.18f, 0.5f);
				if (StepTimer >= Interval)
				{
					StepTimer = 0.0f;
					if (Sand != nullptr) Sand.Footstep(Feet, 0.5f);
					if (Court != nullptr) Court.DeformSand(Feet, 16.0f, 3.0f);
				}
			}
			else StepTimer = 0.0f;
		}

		// Hit cooldown
		if (!bCanHit)
		{
			HitTimer += DeltaTime;
			if (HitTimer >= HitCooldown) { bCanHit = true; HitTimer = 0; }
		}

		if (ReachTimer > 0.0f) ReachTimer -= DeltaTime;

		// Auto-reach: whenever the ball is close and I'm allowed to play it, hold
		// the arms out toward it (pose chosen by height) so the gesture is a held
		// motion regardless of AI role. The AI's Reach() can still override type.
		AutoReachForBall();

		// SINGLE rotation authority. Prefer the AI's desired facing (e.g. toward the
		// ball); otherwise face the travel direction so locomotion reads correctly.
		// Always a smooth lerp — never a snap — so the body never jerks.
		// A facing request HOLDS for a beat (same lapse pattern as Reach/crouch):
		// the AI only re-asserts every reaction tick (~0.1s), and clearing the
		// request per frame made the rotation target alternate ball-facing on
		// tick frames / travel-facing between them — a visible two-pose shimmer.
		//
		// FacingDir ITSELF is rate-limited before use (SmFacingDir): the AI
		// recomputes it whole-cloth from the live ball bearing every reaction
		// tick, and a close/fast ball can swing that bearing through a large
		// angle in one tick. The body's lerp toward Want is already smooth,
		// but a smooth chase of a TARGET that itself teleports still reverses
		// the output turn direction the instant the target crosses to the
		// other side — the exact yaw-rate-sign-flip the motion monitor was
		// still catching after every source-side (bTurnRun) dwell fix. Rate-
		// limiting the target directly removes the reversal at its root
		// instead of chasing which system supplied it.
		if (FacingDir.SizeSquared() > 0.01f)
		{
			float CurYaw = SmFacingDir.Rotation().Yaw;
			float TargetYaw = FacingDir.Rotation().Yaw;
			float Step = Math::Clamp(Math::FindDeltaAngleDegrees(CurYaw, TargetYaw),
				-FacingDirMaxTurnRate * DeltaTime, FacingDirMaxTurnRate * DeltaTime);
			SmFacingDir = FRotator(0.0f, CurYaw + Step, 0.0f).Vector();
		}

		float HSpeed2 = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0).Size();
		if (bHasFacing)
			FacingHoldTimer = 0.2f;
		else
			FacingHoldTimer -= DeltaTime;

		FVector InFlat = FVector(MoveInput.X, MoveInput.Y, 0);
		FVector VelFlat = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0);
		// Face where the CAPSULE is going, not the AI's latest command.
		// Command-as-travel made every reverse a backpedal: input flips 180°,
		// the chest follows, velocity is still the old way for the whole
		// brake — ForwardSpeed stays negative until the slide dies. Velocity
		// as travel keeps the run clip honest (forward run while braking,
		// then turn as the new direction actually starts).
		FVector TravelFlat = (HSpeed2 > 80.0f) ? VelFlat
			: ((InFlat.SizeSquared() > 0.01f) ? InFlat : VelFlat);
		// TRAVEL WINS WHILE MOVING. FaceBall / the tick-rate watch fallback
		// keep a facing request live almost every in-play frame; if that
		// request is allowed to own yaw during a jog, the blendspace plays
		// the forward-run clip while the capsule goes the other way — bent
		// forward, backpedaling, "nästan hela tiden". Square up to the ball
		// only in the air (spike uncoil) or once the run has actually stopped.
		bool bTravelWins = bIsGrounded && !IsDiving()
			&& (HSpeed2 > 80.0f || InFlat.Size() > 0.15f)
			&& TravelFlat.SizeSquared() > 0.01f;
		bTurnRun = bTravelWins;

		FVector RawWant = FVector::ZeroVector;
		if (bTravelWins)
			RawWant = TravelFlat;
		else if (FacingHoldTimer > 0.0f && FacingDir.SizeSquared() > 0.01f)
			RawWant = FVector(SmFacingDir.X, SmFacingDir.Y, 0);
		else if (HSpeed2 > 30.0f)
			RawWant = VelFlat;

		// ALL THREE SOURCES pass through one rate-limited target, not just the
		// held-request one. Only src=1 was smoothed before, so the two unsmoothed
		// paths (velocity, turn-and-run) and — worse — every SWITCH between the
		// three handed the body a target that had teleported. Measured over 142
		// flips: none sat near the 180° band RotDirBias guards, the sources were
		// churning 65/45/32 between themselves instead. Smoothing the SELECTED
		// target makes a source change a continuous move rather than a step.
		if (RawWant.SizeSquared() > 0.01f)
		{
			if (SmWantDir.SizeSquared() < 0.01f) SmWantDir = RawWant.GetSafeNormal2D();
			float CurWantYaw = SmWantDir.Rotation().Yaw;
			float NewWantYaw = RawWant.Rotation().Yaw;
			// Ball-watch tracks at 300 deg/s so a swinging bearing doesn't
			// whip the chest. Travel retargets faster — the old 300° cap on
			// THIS vector meant a 180° "turn and run" spent 0.6s with
			// ForwardSpeed still negative (body chasing a target that itself
			// was only halfway around). BodyMaxTurnRate still caps the actor.
			float WantRate = bTravelWins ? 1800.0f : FacingDirMaxTurnRate;
			float WStep = Math::Clamp(Math::FindDeltaAngleDegrees(CurWantYaw, NewWantYaw),
				-WantRate * DeltaTime, WantRate * DeltaTime);
			SmWantDir = FRotator(0.0f, CurWantYaw + WStep, 0.0f).Vector();
		}
		FVector Want = SmWantDir;

		if (Want.SizeSquared() > 0.01f)
		{
			// Manual yaw step instead of a fresh LerpShortestPath every frame.
			// CONFIRMED (YFLIP telemetry, dt rock-steady ~1ms — not a frame-
			// pacing artifact): near an exact 180° turn, "shortest path" is
			// numerically DEGENERATE — clockwise and counter-clockwise are
			// equally short, so a fraction of a degree of float noise in Cur
			// or Want flips which way LerpShortestPath picks, reversing the
			// output rotation direction between two adjacent frames at full
			// rate. Once a turn is committed to a direction, keep going that
			// way through the ambiguous zone (RotDirBias) instead of letting
			// each frame re-decide "shortest" from scratch.
			FRotator Cur = GetActorRotation();
			float TargetYaw = Want.Rotation().Yaw;
			float Delta = Math::FindDeltaAngleDegrees(Cur.Yaw, TargetYaw);
			bool bDeltaPos = Delta >= 0.0f;
			bool bBiasPos = RotDirBias >= 0.0f;
			if (Math::Abs(RotDirBias) > 1.0f && Math::Abs(Math::Abs(Delta) - 180.0f) < 15.0f
				&& bDeltaPos != bBiasPos)
				Delta = bDeltaPos ? Delta - 360.0f : Delta + 360.0f;
			if (Math::Abs(Delta) > 1.0f) RotDirBias = Delta;

			// Proportional approach with an ATHLETIC CEILING. The gain alone is
			// uncapped: a 180° error yields 180*8 = 1440 deg/s on the first frame,
			// and the live telemetry measured a 566 deg/s median and 1239 deg/s
			// peak — four times FacingDirMaxTurnRate, which only ever limited the
			// target. A human pivoting hard manages roughly 400-500 deg/s; past
			// that the body reads as a turret, not a player. Same shape the crouch
			// sink argues for: proportional so micro-corrections stay micro, with
			// the cap only catching the outliers.
			float Alpha = Math::Clamp(8.0f * DeltaTime, 0.0f, 1.0f);
			float Step = Delta * Alpha;
			// Clear backpedal: rotate out of the conflict faster than the athletic
			// cruise rate. 450 deg/s needs ~0.4s for a 180° — during that whole
			// window ForwardSpeed stays negative and the eye reads "crawling
			// backwards" even though turn-and-run already picked travel. Cap at
			// 720 (still under a snap) only while the body is still opposing
			// the commanded travel.
			float MaxRate = BodyMaxTurnRate;
			if (bTravelWins && TravelFlat.SizeSquared() > 0.01f)
			{
				float BodyAlign = GetActorForwardVector().GetSafeNormal2D()
					.DotProduct(TravelFlat.GetSafeNormal());
				if (BodyAlign < -0.2f)
					MaxRate = 720.0f;
			}
			float MaxStep = MaxRate * DeltaTime;
			Step = Math::Clamp(Step, -MaxStep, MaxStep);
			SetActorRotation(FRotator(Cur.Pitch, Cur.Yaw + Step, Cur.Roll));
		}
		// Debug attribution for YFLIP (see UpdateMotionMonitor): which source
		// picked this frame's facing target, and what it pointed at.
		DbgFacingSrc = bTurnRun ? 2 : ((FacingHoldTimer > 0.0f && FacingDir.SizeSquared() > 0.01f) ? 1 : 0);
		DbgWantYaw = (Want.SizeSquared() > 0.01f) ? Want.Rotation().Yaw : DbgWantYaw;
		bHasFacing = false;   // requests lapse via FacingHoldTimer above

		UpdateAnimation(DeltaTime, HSpeed2);
		UpdateMotionMonitor(DeltaTime);
	}

	// Feed movement + hit state into the AnimInstance. The Anim Blueprint reads
	// these and does the actual blending in its AnimGraph.
	private void UpdateAnimation(float DeltaTime, float HSpeed)
	{
		GestureAge += DeltaTime;

		// Decay the swing timer. Keep CurrentHit set until the pose has fully
		// relaxed (below) so the arm doesn't snap to neutral mid-gesture.
		if (HitAnimTimer > 0.0f)
		{
			HitAnimTimer -= DeltaTime;
			if (HitAnimTimer < 0.0f) HitAnimTimer = 0.0f;
		}

		if (Anim == nullptr)
		{
			if (Mesh != nullptr)
				Anim = Cast<UVolleyballAnimInstance>(Mesh.GetAnimInstance());
			if (Anim == nullptr) return;
		}

		// Local-space velocity so the Anim BP can blend fwd/back/strafe directionally
		FVector Fwd   = GetActorForwardVector();
		FVector Right = GetActorRightVector();
		FVector FlatVel = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0);

		// Tried flooring this to bias the blend space away from its Speed=0
		// (MM_Idle) sample toward Walk, on the theory that Idle alone carried
		// a bad forward lean. Measured and reverted: a live bone trace during
		// ACTUAL movement (spd=300-350, real AI running) showed headFwd still
		// 57-60 — Walk carries the identical lean. It's not one bad sample,
		// it's this whole asset pack's body language (a combat-alert stance
		// pulled from a shooter template), baked into the spine bones' own
		// rotation keyframes in EVERY locomotion clip, so no blend-space bias
		// could ever fix it.
		//
		// Also tried and REVERTED: a Modify Bone node on spine_01
		// (AnimGraphNode_ModifyBone_1), added fresh via MCP's
		// add_blueprint_node and spliced in right after the raw blend-space
		// pose, meant to rotate the lean back out. Fully wired and configured
		// (verified via Python reflection: correct bone, BMM_ADDITIVE and
		// BMM_REPLACE both tried, BCS_BONE_SPACE, Alpha=1, and — after finding
		// the node's struct property and its PIN default are two separate
		// stores that do not sync from Python — set at the pin level too).
		// Zero measured effect at any rotation value up to 150deg, in either
		// mode. A node this session created from scratch, unlike the earlier
		// IKRig reconnection (which only rewired EXISTING nodes and worked),
		// so the leading theory is that AnimGraph's specialized compile pass
		// isn't fully regenerating the runtime evaluation list for a
		// brand-new node via this MCP path. Removed rather than left in a
		// state that looks wired but silently does nothing. The lean is
		// still real, still unfixed, and now precisely characterized (see
		// the TRACE block below) for whoever picks this up next — most
		// likely a human placing the same node by hand in the editor GUI, or
		// swapping in genuinely different (non-combat) source animations.
		Anim.Speed = HSpeed;
		Anim.ForwardSpeed  = FlatVel.DotProduct(Fwd);
		Anim.StrafeSpeed   = FlatVel.DotProduct(Right);
		// Travel-vs-facing angle for an orientation-aware blendspace. Only updated
		// while actually moving: recomputing it from near-zero velocity sprayed
		// noise, and holding the last heading keeps the blend continuous through
		// stops. With the turn-and-run override this stays near 0 during real
		// runs; the residual backpedal/shuffle band is what the ABP can now blend.
		if (HSpeed > 30.0f)
			Anim.MoveDirAngle = Math::Atan2(Anim.StrafeSpeed, Anim.ForwardSpeed) * (180.0f / PI);
		// HYSTERESIS: a single threshold made bIsMoving flip every frame when
		// the speed hovered at the boundary (deceleration, hold drift), and the
		// Anim BP popped between the idle and locomotion poses at frame rate.
		bMovingState = bMovingState ? (HSpeed > 30.0f) : (HSpeed > 70.0f);
		Anim.bIsMoving     = bMovingState;
		// NOT DONE HERE: scaling playback by ground speed. MM_Run_Fwd travels at
		// 532 cm/s at rate 1.0 (measured off the asset), so Speed/532 through
		// Mesh.GlobalAnimRateScale looks like the obvious cure for foot sliding.
		// It was tried and MEASURED WORSE on every metric — slowing the clip below
		// rate 1 costs more knee motion than the stride match buys:
		//   footSlide/s     198 -> 221      kneeTravel/s   151 -> 104
		//   straight-leg frames  58/120 -> 67/120
		// Reverted rather than shipped. The real fix is a speed-driven blendspace
		// (BS_VolleyballLocomotion exists, with idle/walk/run samples placed at
		// each clip's own measured travel speed) — it just needs a BlendSpacePlayer
		// node, which nothing outside the editor GUI can create.
		Anim.bIsInAir      = !bIsGrounded;
		Anim.VerticalSpeed = PlayerVelocity.Z;
		// THIS WAS HARDCODED false AND IT LOCKED EVERY PLAYER INTO THE DEATH
		// CLIP FOR MONTHS. The old comment here claimed BlendListByBool is
		// "standard, not inverted" and that false picks the real chain. It is
		// the other way round, and the proof is a measurement, not a reading of
		// the engine source: MM_Death_Front_01 is 1.100s long, and the pose
		// telemetry cycled with a period of 1.09-1.10s while bDiving sat at
		// false the whole time. The "mystery oscillation" everyone chased was
		// simply that clip looping. Booth idle also measured head 5cm ABOVE the
		// pelvis and 59cm in FRONT of it — a face-plant, not a stance.
		//
		// So: bActiveValue TRUE selects BlendPose_0, FALSE selects BlendPose_1,
		// and the pins are now wired to match (BlendPose_0 = the death clip,
		// BlendPose_1 = the real locomotion/IK chain). With that wiring the
		// honest value below is correct again.
		Anim.bDiving       = IsDiving() || bRagdollActive;

		Anim.bIsHitting = HitAnimTimer > 0.0f || bReaching;
		Anim.HitType    = CurrentHit;
		int Clip = HitClipIndexFor(CurrentHit);
		Anim.HitClipBranch = (Clip > 0) ? 1 : 0;
		Anim.HitSetSpikeBlend = (Clip == 2) ? 1.0f : 0.0f;

		// Head tracks the ball: ALWAYS look at it while it's in play, so every
		// player keeps their eyes on the ball — Erik's own stated design goal
		// for this project. A HSpeed<120 gate was added here at some point,
		// turning head tracking off while running; reverted; it isn't
		// physically necessary (a real player watches the ball over their
		// shoulder mid-run — see the comment on the near-field bearing fix in
		// AIPlayer.as) and the head LookAt is a separate skeletal control
		// from body facing, so it doesn't fight travel the way the body's own
		// rotation authority can. The Anim BP drives a Look At node on the
		// head bone toward LookTarget with weight LookAlpha.
		{
			ABall LB = GetWorldBall();
			if (LB != nullptr && LB.bInPlay)
			{
				Anim.LookTarget = LB.Position;
				Anim.LookAlpha  = 1.0f;
			}
			else
			{
				Anim.LookAlpha  = 0.0f;   // no ball to watch — relax to neutral
			}
		}

		// Two phases:
		//  - REACHING: while waiting for the ball, hold the arms extended toward
		//    it (steady pose) so the hands/forearms are where the ball arrives.
		//  - SWING: at contact, a 0->1->0 envelope swings the arms through.
		float TargetPose;
		if (HitAnimTimer > 0.0f)
		{
			float Progress = (HitAnimDuration > 0.0f)
				? 1.0f - Math::Clamp(HitAnimTimer / HitAnimDuration, 0.0f, 1.0f)
				: 0.0f;
			TargetPose = Math::Sin(Progress * PI);   // 0..1..0 swing
		}
		else if (bReaching)
		{
			TargetPose = 0.85f;   // hold arms extended, ready
		}
		else
		{
			TargetPose = 0.0f;    // arms relax to neutral
		}

		// Smoothly ease the actual pose toward the target so arms move fluidly
		// instead of snapping between reach / swing / neutral each frame.
		float Speed = (TargetPose > CurrentPose) ? 14.0f : 8.0f;  // reach fast, relax slower
		float Alpha = Math::Clamp(Speed * DeltaTime, 0.0f, 1.0f);
		CurrentPose = CurrentPose + (TargetPose - CurrentPose) * Alpha;

		// IK Alpha and pose SHAPE are separate concerns. The IK node should apply
		// (nearly) fully whenever we're gesturing, so the hands actually reach the
		// targets — NOT scaled by CurrentPose, or we'd double-dampen (40% reach *
		// 40% IK = 16% visible motion, which read as "arms barely move").
		// CurrentPose instead drives only the ready->contact SHAPE inside
		// UpdateIKTargets. We ramp IKAlpha quickly to 1 once any gesture starts.
		float TargetIK = (CurrentPose > 0.02f) ? 1.0f : 0.0f;
		float IKSpeed = (TargetIK > IKWeight) ? 12.0f : 6.0f;
		IKWeight = IKWeight + (TargetIK - IKWeight) * Math::Clamp(IKSpeed * DeltaTime, 0.0f, 1.0f);

		// Attack clips are full-body mocap — blending them during the reach hold
		// (CurrentPose 0.85) overrides the legs and reads as crawling backwards.
		// IK owns reach; reserve HitAlpha for the contact swing only.
		Anim.HitAlpha = (HitAnimTimer > 0.0f) ? CurrentPose : 0.0f;
		// IKAlpha=1 (was forced permanently) was working around the IK Rig
		// node's Source pin being DISCONNECTED in the ABP — with nothing
		// feeding it a pose, it fell back to the skeleton's bind pose
		// regardless of Alpha, so forcing Alpha to 1 was the only way to get
		// the (still bind-pose-based) hand goals to show at all. Fixed at the
		// graph level instead: Source is now wired to the real locomotion +
		// hit-overlay chain (execute_python, AnimGraphNode_IKRig_0.Source <-
		// AnimGraphNode_TwoWayBlend_2.Pose, AnimGraphNode_IKRig_0.Pose ->
		// AnimGraphNode_LocalToComponentSpace_6.LocalPose). With a real pose
		// now flowing in, Alpha=0 passes it through unmodified — which is
		// what locomotion needs — and only a live gesture should pull the
		// hands away from it, so this goes back to the smoothed IKWeight.
		Anim.IKAlpha = IKWeight;
		// Pose shape uses the full 0..1 gesture curve, remapped so even the 0.85
		// reach hold reaches the contact shape (reach should look committed).
		float Shape = Math::Clamp(CurrentPose / 0.85f, 0.0f, 1.0f);
		// Ease the handed-over meet point before the poses read it (see
		// SmReachContact). Snapped on the first frame of a reach — there is
		// nothing to ease from, and starting at the previous ball's contact
		// point would drag the platform across the court.
		if (bHasReachContact)
		{
			if (!bSmReachInit)
			{
				SmReachContact = ReachContact;
				bSmReachInit = true;
			}
			else
			{
				float EaseA = Math::Clamp(DeltaTime / ReachEaseTime, 0.0f, 1.0f);
				SmReachContact += (ReachContact - SmReachContact) * EaseA;
			}
		}
		else bSmReachInit = false;
		this.UpdateIKTargets(Shape, DeltaTime);   // mixin in PlayerIK.as

		// Once the gesture has fully relaxed and we're no longer hitting/reaching,
		// release the hit type so the next contact can pick a fresh one. The
		// release respects the same dwell as Reach — a release/re-reach cycle
		// is just as much a flicker as a type swap.
		if (HitAnimTimer <= 0.0f && !bReaching && CurrentPose < 0.02f
			&& CurrentHit != EHitType::Hit_None && GestureAge >= MinGestureDwell)
		{
			CurrentHit = EHitType::Hit_None;
			GestureAge = 0.0f;
			GestureClock = 0.0f;
		}

		// Per-attempt summary tracking: while gesturing, remember how close the hand
		// actually got to the ball. Emit ONE line when the attempt ends — far less
		// noise than per-frame, and it answers the real question: did the hand reach
		// the ball, and did it score a contact? The serve gesture is excluded: the
		// server "chasing" his own departing serve polluted the miss statistics.
		if (CurrentPose > 0.05f && CurrentHit != EHitType::Hit_Serve)
		{
			ABall TB = GetWorldBall();
			if (TB != nullptr && TB.bInPlay && Mesh != nullptr)
			{
				bAttemptActive = true;
				float DR = (TB.Position - Mesh.GetBoneTransform(n"hand_r").Location).Size();
				float DL = (TB.Position - Mesh.GetBoneTransform(n"hand_l").Location).Size();
				float D = Math::Min(DR, DL);
				if (D < AttemptClosest)
				{
					AttemptClosest = D;
					// Record body vs ball gap at the closest moment, split into
					// horizontal vs vertical so we can tell WHY the hand misses:
					// big horiz = standing beside it; big vert = ball too high/low.
					FVector Loc = GetActorLocation();
					AttemptHoriz = (Loc - FVector(TB.Position.X, TB.Position.Y, 0)).Size2D();
					AttemptVert  = TB.Position.Z - (Loc.Z + PlayerHeight);  // + above head
					AttemptPose  = CurrentPose;
					AttemptIK    = IKWeight;
					// Facing error: angle between where we look and where the ball is.
					FVector ToBallFlat = FVector(TB.Position.X - Loc.X, TB.Position.Y - Loc.Y, 0).GetSafeNormal();
					AttemptFacing = GetActorForwardVector().DotProduct(ToBallFlat);  // 1=facing, -1=away
					// THE decisive number: how far the actual hand is from the target
					// we ASKED the IK for. Small = IK follows target (our target is
					// wrong); large = IK ignores target (wiring/space is wrong).
					FVector HandR = Mesh.GetBoneTransform(n"hand_r").Location;
					AttemptHandVsTarget = (HandR - Anim.HandTargetR).Size();
					// And how far our target itself is from the ball.
					AttemptTargetVsBall = (Anim.HandTargetR - TB.Position).Size();
				}
			}
		}
		else if (bAttemptActive)
		{
			// Attempt just ended — report closest approach vs the catch radius.
			if (bDebugHit)
			{
				ABall CB = GetWorldBall();
				float Catch = ArmContactRadius + (CB != nullptr ? CB.BallRadius : 10.66f);
				Log("ATTEMPT type=" + int(CurrentHit)
					+ " closestHand=" + int(AttemptClosest)
					+ " catch=" + int(Catch)
					+ " | bodyHoriz=" + int(AttemptHoriz)
					+ " ballVsHead=" + int(AttemptVert)
					+ " pose=" + int(AttemptPose * 100)
					+ " ik=" + int(AttemptIK * 100)
					+ " facing=" + int(AttemptFacing * 100)
					+ " | handVsTarget=" + int(AttemptHandVsTarget)
					+ " targetVsBall=" + int(AttemptTargetVsBall)
					+ (AttemptClosest <= Catch ? "  -> SHOULD HIT" : "  -> MISS"));
			}
			bAttemptActive = false;
			AttemptClosest = 99999.0f;
		}

		// Reach/crouch requests lapse on a short timer (see Reach/RequestCrouch)
		// so they survive the gap between AI reaction ticks but still fade when
		// the AI stops asking.
		ReachHoldTimer -= DeltaTime;
		ReachTau = Math::Max(ReachTau - DeltaTime, 0.0f);
		if (ReachHoldTimer <= 0.0f)
		{
			bReaching = false;
			bHasReachContact = false;
			bSmReachInit = false;
			ReachTau = 99.0f;
		}
		// (Crouch decay moved to the TOP of UpdatePlayer — it must run before
		// the per-frame writers, not after them.)
	}

	private bool bAttemptActive = false;
	private float AttemptClosest = 99999.0f;
	private float AttemptHoriz = 0.0f;
	private float AttemptVert = 0.0f;
	private float AttemptPose = 0.0f;
	private float AttemptIK = 0.0f;
	private float AttemptFacing = 0.0f;
	private float AttemptHandVsTarget = 0.0f;
	private float AttemptTargetVsBall = 0.0f;

	private float CurrentPose = 0.0f;   // smoothed arm-pose SHAPE weight (ready->contact)
	private float IKWeight = 0.0f;      // smoothed IK node Alpha (how much IK applies)
	private bool bMovingState = false;  // hysteresis state for Anim.bIsMoving

	// --- Motion naturalness monitor ----------------------------------------
	// DETECTS unnatural motion signatures directly instead of waiting for a
	// human to spot them: velocity direction reversals, yaw oscillation,
	// crouch flapping, and IK-sink violations, each over a sliding window.
	// Emits JITTER log lines that headless runs grep — the permanent motion-
	// quality regression check.
	bool bMonitorMotion = true;
	private float MonWindow = 0.0f;
	private int MonMoveFlips = 0;
	private int MonYawFlips = 0;
	private int MonCrouchFlips = 0;
	private int MonIKTeleports = 0;
	private FVector MonPrevVel;
	private float MonPrevYaw = 0.0f;
	private float MonPrevYawDelta = 0.0f;
	private float MonPrevCrouch = 0.0f;
	private float MonPrevCrouchDelta = 0.0f;
	private FVector MonPrevHandR;
	// HAND JERK, the thing "stötiga slaganimationer" actually is. The teleport
	// check above only catches the hand target moving too FAST; a gesture can sit
	// inside that speed ceiling the whole time and still look like it is being
	// shoved, because what the eye reads as a jolt is a reversal — the hand
	// changing direction sharply between frames. Measured only while a hit
	// gesture is live, so ordinary repositioning does not dilute it.
	private FVector MonPrevHandStep;
	private bool bMonHandStepInit = false;
	private int MonHandJerks = 0;
	private int MonTotHandJerks = 0;
	private float MonHandTurnMax = 0.0f;
	private float MonHandGestureTime = 0.0f;
	private int MonJerkLogs = 0;
	// PLATFORM AMPLIFICATION probe: last frame's meet point and the platform end
	// it produced, so the bump branch can report how much a given wobble in the
	// meet point moved the hand. Public — PlayerIK is a mixin and writes them.
	FVector MonPrevReachC;
	FVector MonPrevPlatEnd;
	bool bMonPlatInit = false;
	int MonPlatLogs = 0;
	private bool bMonInit = false;
	private int MonCFlipLogs = 0;
	// Written by UpdateIKTargets each frame so CFLIP can attribute the source.
	float DbgPoseCrouch = 0.0f;
	float DbgWantCrouch = 0.0f;
	// The sink's legitimate speed ceiling this frame (swing boost included) —
	// written by UpdateIKTargets so the teleport check tracks the same limit.
	float SinkBoostLog = 1.0f;
	// Rolling peak of the hand-target speed (cm/s), decaying — logged by
	// TriggerHit as the SWING line so whip speeds are measurable per stroke.
	float PeakHandSpd = 0.0f;
	// Facing attribution written each frame (see the rotation block in
	// UpdatePlayer) so a YFLIP log can attribute WHICH source's target
	// reversed: 0=travel-velocity, 1=held facing request, 2=turn-and-run.
	int DbgFacingSrc = -1;
	float DbgWantYaw = 0.0f;
	private int MonYFlipLogs = 0;
	private float MonPrevDt = 0.0f;   // testing whether YFLIP correlates with erratic frame pacing

	// RUN TOTALS — the window counters above reset every 0.5s and only ever print
	// on threshold breach, so a clean run and a run where the monitor silently
	// stopped working look identical, and a worse build can log the same capped
	// 60 YFLIP lines as a better one. These accumulate for the whole rally and are
	// emitted unconditionally as MOTIONSTATS, with seconds-in-motion as the
	// denominator so two runs of different length are comparable.
	private int MonTotMoveFlips = 0;
	private int MonTotYawFlips = 0;
	private int MonTotCrouchFlips = 0;
	private int MonTotIKTeleports = 0;
	private float MonMovingTime = 0.0f;
	private float MonYawRateSum = 0.0f;    // |rate| while turning, for the mean
	private float MonYawRateSamples = 0.0f;
	private float MonYawRateMax = 0.0f;
	// Goal jumps: the movement TARGET teleporting is invisible to every detector
	// above — MoveToHold absorbs it into a perfectly smooth run in the wrong
	// direction, so no velocity or yaw reversal ever fires. Threshold sits above
	// MoveToHold's 110cm StartMoving, i.e. only jumps big enough to actually make
	// the player run somewhere else count.
	private FVector MonPrevGoal;
	private bool bMonGoalInit = false;
	private int MonGoalJumps = 0;        // worst goal path/extent ratio x100
	private float MonGoalPath = 0.0f;
	private float MonGoalExtent = 0.0f;
	private FVector MonGoalStart;

	// ---------------------------------------------------------------
	// WASTED TRAVEL — the one jitter measure that cannot go blind.
	//
	// Every other detector in this file measures a DERIVATIVE (velocity reversal,
	// yaw-rate reversal, crouch-rate reversal) and asks for a sign change between
	// adjacent samples. That is provably useless here, because every writer is
	// now rate-limited: ApplyMoveInput caps a one-frame velocity change at
	// GroundDecel*Dt = 20 cm/s at 60fps, while MonMoveFlips needs 93 cm/s to
	// fire. It CANNOT trip above ~13fps no matter how violently the player
	// shuttles. The same holds for yaw (needs 15 deg/frame, the rate limiters
	// allow 12.5) and crouch (needs 7cm of hip travel). Rate limiting guarantees
	// the derivative passes smoothly through zero, which guarantees the
	// reversal test fails — the anti-flicker machinery and the jitter detectors
	// were tuned against each other into mutual blindness.
	//
	// So measure DISPLACEMENT instead — specifically, HOW MANY TIMES THE PLAYER
	// COVERED THE SAME GROUND. Over a short window, compare the distance walked
	// against the spatial EXTENT of the window (how far from the start they ever
	// got). That ratio is the number of times they crossed their own ground:
	//
	//   straight run          path = extent          -> 1.0
	//   curved intercept      path slightly > extent -> 1.1-1.3
	//   out and back once     path = 2 x extent      -> 2.0
	//   shuttling N times     path = 2N x extent     -> 2N
	//
	// Extent, not net displacement. The first version of this used
	// path-minus-net, which scores every CURVE as waste — a player arcing onto
	// an intercept looks exactly like a vibration to it, and a detector that
	// flags legitimate motion is nearly as useless as one that is blind, because
	// it sends you off fixing things that were never broken. Dividing by extent
	// is scale-free and curvature-tolerant while still being unbounded for a
	// true shuttle, which is the only shape that revisits its own ground.
	//
	// Nothing here is a derivative, so no rate limiter can hide anything from it.
	const float WasteWindowSecs = 0.7f;
	// Below this the window is a player standing still; the ratio is meaningless
	// and would divide by noise.
	const float WasteMinPath = 25.0f;
	private float MonWasteWindow = 0.0f;
	private float MonWastePath = 0.0f;       // cm walked inside the window
	private float MonWasteExtent = 0.0f;     // furthest we ever got from the start
	private FVector MonWasteStart;           // where the window began
	private FVector MonPrevPos;
	private bool bMonWasteInit = false;
	private float MonWasteWorst = 0.0f;      // worst path/extent ratio x100 this rally
	private float MonWasteTotal = 0.0f;      // cm of revisited ground this rally

	private void UpdateWastedTravel(float DeltaTime)
	{
		FVector P = GetActorLocation();
		if (!bMonWasteInit)
		{
			bMonWasteInit = true;
			MonPrevPos = P;
			MonWasteStart = P;
			return;
		}

		MonWastePath += (P - MonPrevPos).Size2D();
		MonPrevPos = P;
		float R = (P - MonWasteStart).Size2D();
		if (R > MonWasteExtent) MonWasteExtent = R;

		MonWasteWindow += DeltaTime;
		if (MonWasteWindow < WasteWindowSecs) return;

		if (MonWastePath >= WasteMinPath && MonWasteExtent > 1.0f)
		{
			float Ratio = MonWastePath / MonWasteExtent;
			if (Ratio * 100.0f > MonWasteWorst) MonWasteWorst = Ratio * 100.0f;
			// Ground covered more than once, in cm — the absolute cost of the
			// churn, which the ratio alone hides for a small tight shuffle.
			MonWasteTotal += Math::Max(MonWastePath - MonWasteExtent, 0.0f);
		}

		MonWasteWindow = 0.0f;
		MonWastePath = 0.0f;
		MonWasteExtent = 0.0f;
		MonWasteStart = P;
	}

	// ---------------------------------------------------------------
	// THE SAME PRIMITIVE, ON THE DEGREES OF FREEDOM IT DID NOT COVER.
	//
	// UpdateWastedTravel was introduced with the claim that it "cannot go blind".
	// That was true, and insufficient: it watches TRANSLATION. A planted player
	// rocking on the spot walks a path of length zero, so it reports a perfectly
	// straight 100 forever while the entire body visibly shakes — which is
	// exactly what the live run showed while the shake was being reported.
	//
	// Yaw and crouch were still guarded only by the derivative flip counters,
	// and those are blind for the reason spelled out above: every writer is
	// rate-limited, so the derivative always passes smoothly through zero.
	// yawFlips read 0 on rallies whose YFLIP dumps show the body reversing at
	// +-100 deg/s with the feet stationary.
	//
	// Revisit ratio does not care which quantity it is fed, only that the
	// quantity has a path and an extent. Steady turn: path == extent -> 1.0.
	// Rock back and forth N times: 2N. No threshold, no rate, nothing a limiter
	// can hide behind. Three channels now share it — position, yaw, crouch —
	// which is the point: the guard belongs to the measurement, not to a list of
	// specific bugs someone remembered to write a detector for.
	private float MonRotWindow = 0.0f;
	private float MonYawPath = 0.0f;         // degrees turned inside the window
	private float MonYawSpan = 0.0f;         // furthest from the window's start yaw
	private float MonYawWinStart = 0.0f;
	private float MonYawRevisit = 0.0f;      // worst yaw path/extent x100 this rally
	// AMPLITUDE, not just shape. yawRevisit is a RATIO, so a body rocking half a
	// degree scores exactly what a body rocking a hundred degrees does — it read
	// FAIL at ~55% of windows in a build with the visible shake and in the build
	// that fixed it, which makes it a constant, not a gauge. This is the same
	// path-minus-extent primitive in degrees: what a viewer actually sees.
	private float MonYawWaste = 0.0f;        // worst degrees turned-and-returned in one window
	// ...and the same amplitude, aggregated over the windows where the FEET DO
	// NOT MOVE, which is the only condition under which turning is unambiguously
	// pointless. A max-over-windows cannot separate builds here (one bad window
	// in ten minutes of play is not the complaint); a rate can. Measured on the
	// build that shipped the shake: 16.7 deg wasted per standing-second while
	// preparing a dig against 6.1 anywhere else.
	private float MonYawWasteStill = 0.0f;
	private float MonYawStillSecs = 0.0f;
	private float MonWinStillTime = 0.0f;
	private float MonYawRevisitWin = 100.0f; // this window's, for the JITTER gate
	private float MonCrPath = 0.0f;
	private float MonCrSpan = 0.0f;
	private float MonCrWinStart = 0.0f;
	private float MonCrRevisit = 0.0f;
	private float MonCrRevisitWin = 100.0f;
	private float MonPrevYawRaw = 0.0f;
	private float MonPrevCrouchRaw = 0.0f;
	private bool bMonRotInit = false;
	// Below these the channel is holding still and the ratio would divide by
	// noise. 20 deg of turning inside 0.7s is a real turn; 0.15 of crouch is a
	// real knee bend.
	const float RevisitMinYaw = 20.0f;
	const float RevisitMinCrouch = 0.15f;
	// Per-frame waveform dump for shake_scope.py. ~4 lines/frame; a 90s run is
	// about 3MB of log, which is why it is a switch and not always on.
	const bool bTraceMotion = false;
	private float MonTraceT = 0.0f;

	private void UpdateRotRevisit(float DeltaTime, float Yaw, float Crouch)
	{
		if (!bMonRotInit)
		{
			bMonRotInit = true;
			MonPrevYawRaw = Yaw;
			MonPrevCrouchRaw = Crouch;
			MonYawWinStart = Yaw;
			MonCrWinStart = Crouch;
			return;
		}

		MonYawPath += Math::Abs(Math::FindDeltaAngleDegrees(MonPrevYawRaw, Yaw));
		MonPrevYawRaw = Yaw;
		float YSpan = Math::Abs(Math::FindDeltaAngleDegrees(MonYawWinStart, Yaw));
		if (YSpan > MonYawSpan) MonYawSpan = YSpan;

		MonCrPath += Math::Abs(Crouch - MonPrevCrouchRaw);
		MonPrevCrouchRaw = Crouch;
		float CSpan = Math::Abs(Crouch - MonCrWinStart);
		if (CSpan > MonCrSpan) MonCrSpan = CSpan;

		MonRotWindow += DeltaTime;
		if (FVector(PlayerVelocity.X, PlayerVelocity.Y, 0).Size() < 30.0f)
			MonWinStillTime += DeltaTime;
		if (MonRotWindow < WasteWindowSecs) return;

		MonYawRevisitWin = 100.0f;
		if (MonYawPath >= RevisitMinYaw && MonYawSpan > 1.0f)
		{
			MonYawRevisitWin = (MonYawPath / MonYawSpan) * 100.0f;
			if (MonYawRevisitWin > MonYawRevisit) MonYawRevisit = MonYawRevisitWin;
		}
		float YawWasteWin = MonYawPath - MonYawSpan;
		if (YawWasteWin > MonYawWaste) MonYawWaste = YawWasteWin;
		if (MonWinStillTime > 0.8f * MonRotWindow)
		{
			MonYawWasteStill += YawWasteWin;
			MonYawStillSecs += MonRotWindow;
		}
		MonWinStillTime = 0.0f;
		MonCrRevisitWin = 100.0f;
		if (MonCrPath >= RevisitMinCrouch && MonCrSpan > 0.01f)
		{
			MonCrRevisitWin = (MonCrPath / MonCrSpan) * 100.0f;
			if (MonCrRevisitWin > MonCrRevisit) MonCrRevisit = MonCrRevisitWin;
		}

		MonRotWindow = 0.0f;
		MonYawPath = 0.0f;
		MonYawSpan = 0.0f;
		MonYawWinStart = Yaw;
		MonCrPath = 0.0f;
		MonCrSpan = 0.0f;
		MonCrWinStart = Crouch;
	}

	// BONE-LEVEL JITTER — the solver's OUTPUT, which is what the eye actually sees.
	// Every detector above watches script INTENT (velocity, yaw, crouch, hand
	// targets). The visible pose is the FBIK solve on top of that, and the solver
	// re-solves the whole chain — pelvis and spine included — from the hand
	// targets every frame, so it can shake while every input reads clean. That is
	// the blind spot the previous pass named and could not measure.
	//
	// footSlide is the classic skating tell: a foot in contact with the sand
	// should be stationary in WORLD space. Any horizontal travel while it is
	// planted is the foot sliding under the body.
	private FVector MonPrevFootL;
	private FVector MonPrevFootR;
	private FVector MonPrevPelvis;
	private FVector MonPrevPelvisVel;
	private bool bMonBoneInit = false;
	private float MonFootSlide = 0.0f;    // cm accumulated while planted
	// COMPENSATION TELEMETRY — how much work a downstream system is silently
	// doing to cover an upstream error. Every bug chased on 2026-09-02/03 was
	// one layer quietly absorbing another's mistake, which is why removing any
	// one of them first made the game WORSE: the compensation went, the error
	// it hid stayed. An absorption that is measured cannot grow unnoticed.
	//
	// This one: how far the full-body IK solver drags the pelvis away from the
	// point the script placed it at (Anim.PelvisTarget). Off a gesture it sits
	// under 1cm; during a dig it measured 38.8cm median and 121.6 at p90 — the
	// solver carrying a receiver who never arrived. Per axis on purpose: a
	// single-axis version of this read "0.1mm, solved" for an afternoon while
	// the sideways component was getting worse.
	// P90, NOT max. The first version of this was a maximum, and a maximum over
	// a rally is dominated by one frame: it flagged a comment-only change as a
	// regression, and in the pre-pull test it read "unchanged at p90" while the
	// median had moved a quarter — useless in both directions. Histogram in 5cm
	// buckets, percentile at emit. (planInfeasible had the same disease and was
	// fixed the same day; see that commit.)
	private TArray<int> MonSlideHistX;
	private TArray<int> MonSlideHistY;
	private TArray<int> MonSlideHistZ;
	const int SlideBuckets = 41;      // 0..200cm in 5cm steps, last bucket is "200+"
	const float SlideBucketCm = 5.0f;
	// ...and the planner's own honesty: bookings whose travel budget does not
	// fit the ball's flight time. Set by the AI at commitment. 70% infeasible
	// was the state of the game while nothing reported it.
	int MonPlanBookings = 0;
	int MonPlanInfeasible = 0;
	// DIAG: was this player's live booking judged unmakeable when it was made?
	bool bBookedInfeasible = false;
	private int MonPelvisFlips = 0;       // pelvis direction reversals (the sink can't see these)

	// KNEE FLEXION — "do the legs actually bend?", measured instead of eyeballed.
	// Every foot/pelvis number above can look perfect while the knees stay locked:
	// a rigid leg whose foot is planted and whose hips hold still scores a clean
	// footSlide of 0 and zero pelvisFlips. What the eye calls "walking on tiptoes"
	// is precisely a knee that never folds, and nothing here could see it.
	//
	// The measure is KneeBend() below: 0 = locked straight, larger = more
	// folded. Accumulated in two buckets because the two cases fail independently
	// and have been confused for each other repeatedly — the legs DO bend on a
	// receive (crouch, standing still) while staying rigid during a walk. A single
	// average blends the working case into the broken one and reads "fine".
	//   walk  = speed above WalkKneeSpeed, i.e. a real gait should be running
	//   still = below it, where the crouch IK is the only thing bending anything
	private float MonKneeWalkSum = 0.0f;
	private float MonKneeWalkSamples = 0.0f;
	private float MonKneeWalkMax = 0.0f;
	private float MonKneeWalkMin = 999.0f;
	private float MonKneeStillSum = 0.0f;
	private float MonKneeStillSamples = 0.0f;
	private float MonKneeStillMax = 0.0f;
	// Bend RANGE over time is the real gait tell: a leg held at a constant bend
	// of 20 is as stiff as one held at 0, and only a CHANGING bend is a stride.
	// This sums how much the left knee's bend moves frame to frame while
	// walking — a genuine walk cycle cranks this up fast, a locked leg leaves it
	// near zero no matter how good the mean looks.
	private float MonKneeWalkTravel = 0.0f;
	private float MonPrevKneeL = -1.0f;
	// Opposite-stride tell: actor-forward offset of left knee minus right knee.
	// A real gait flips the sign every step; locked legs leave this near zero.
	private float MonKneeOppTravel = 0.0f;
	private float MonPrevKneeOpp = 0.0f;
	private bool bMonKneeOppInit = false;
	// Per-frame leg-chain trace. Diagnostic only — set on ONE player by the
	// GameMode so the log stays readable; leave false in normal play.
	bool bKneeTrace = false;
	private int MonKneeTraceLogs = 0;

	// POSE ANOMALY TELEMETRY — answers "are feet under the sand / are we
	// backpedaling bent-forward / is turn-and-run actually on?" without a
	// human at the flipbook. Aggregates go into MOTIONSTATS; POSE lines fire
	// on anomalies (rate-limited) so MatchFilmer logs stay greppable.
	private float MonUnderSandTime = 0.0f;   // seconds with a foot below sole plane
	private float MonBackpedalTime = 0.0f;   // seconds moving with ForwardSpeed < 0
	private float MonTurnRunTime = 0.0f;     // seconds bTurnRun engaged
	private float MonFootZMin = 9999.0f;     // worst (lowest) foot Z this rally
	private float MonKneeZMin = 9999.0f;
	private int MonPoseLogs = 0;
	private float MonPoseLogCooldown = 0.0f;

	// ---------------------------------------------------------------
	// BIOMECHANICAL PLAUSIBILITY — measured against published human values.
	//
	// Every metric above answers "did this change make it better than last
	// time?", which is only ever a comparison against ourselves: a run can win
	// on all of them and still move like nothing alive. These answer the
	// different question "is this what a human body can actually do?", by
	// carrying an absolute target taken from the literature rather than from
	// taste. That is what makes the loop closable without a human watching:
	// a number outside its band is wrong on its own terms, not merely worse.
	//
	// Targets (elite athlete / sports-biomechanics ranges):
	//   peak horizontal accel   <= ~10 m/s^2   (sprint first-step peak)
	//   peak horizontal decel   <= ~12 m/s^2   (hard controlled plant)
	//   airborne accel           = 9.81 m/s^2 down, nothing else touching it
	//   COM vertical oscillation  4-6 cm running
	//   turn rate               <= ~360 deg/s while travelling
	// Values are stored in the units the engine already uses (cm/s^2) and only
	// converted at the log line, so nothing silently mixes units mid-sum.
	// Fastest the body has actually travelled, cm/s. THE RATCHET HAD NO SPEED
	// ROW, and that is how a dive at 10.2 m/s — faster than a sprint record,
	// through sand — lived in the game long enough to be found by accident while
	// reading an aim-error tail. Acceleration was gated from the first day.
	private float MonTopSpeed = 0.0f;
	private float MonPeakAccel = 0.0f;      // cm/s^2, strongest speeding-up
	private float MonPeakDecel = 0.0f;      // cm/s^2, strongest slowing-down
	private float MonPeakPlant = 0.0f;      // cm/s^2, strongest braking inside a jump gather
	private float MonAccelOverBudget = 0.0f;   // seconds spent above the human band
	private float MonPelvisZMin = 99999.0f;    // running COM oscillation, grounded only
	private float MonPelvisZMax = -99999.0f;
	private float MonAirBallisticErr = 0.0f;   // cm/s^2 of non-gravity vertical accel
	private float MonAirSamples = 0.0f;
	private float MonJumpApex = 0.0f;          // cm above standing hip height
	private float MonStandHipZ = -1.0f;
	private float MonStandActorZ = -1.0f;
	private FVector MonPrevVelBio = FVector::ZeroVector;
	private bool bMonBioInit = false;

	// Human bands, in engine units. Deliberately generous — the point is to
	// catch "no human could do that", not to police centimetres.
	const float HumanAccelLimit = 1000.0f;   // cm/s^2 (10 m/s^2)
	// The body can STOP harder than it can start, which is why the report bands
	// them separately (accel 10, decel 12) — and why the over-budget test has to
	// as well. It did not: it charged every frame against the accel limit, so
	// GroundDecel, which is exactly 12 by design, was a violation on every hard
	// stop in the game. The row could not reach its target of zero no matter what
	// the body did.
	const float HumanDecelLimit = 1200.0f;   // cm/s^2 (12 m/s^2)

	private void UpdateBiomech(float DeltaTime)
	{
		if (DeltaTime <= 0.0f || Mesh == nullptr) return;

		FVector V = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0.0f);
		if (!bMonBioInit)
		{
			bMonBioInit = true;
			MonPrevVelBio = V;
			return;
		}

		// Acceleration as a VECTOR, not a change in speed. A player carving a
		// turn at constant pace has real lateral acceleration that the legs must
		// produce, and a speed-magnitude delta scores that as zero — which would
		// pass a sidestep no human could plant hard enough to make.
		//
		// The signed along-track part still splits accel from decel, because the
		// body's limits differ (you can stop harder than you can start), but the
		// over-budget test uses the full magnitude since that is what the ground
		// actually has to push back.
		if (V.Size() > MonTopSpeed) MonTopSpeed = V.Size();
		FVector A = (V - MonPrevVelBio) / DeltaTime;
		if (bIsGrounded)
		{
			float Along = (V.Size() - MonPrevVelBio.Size()) / DeltaTime;
			// A DIVE PUSH-OFF IS A PLANT, and belongs in the plant's band for the
			// same reason the gather does: both are brief explosive ground events
			// at several times bodyweight, and holding them to the sprint band
			// would demand the game be LESS real. Scored in both directions here
			// because a dive accelerates out of the ground where a gather brakes
			// into it.
			bool bExplosiveGround = JumpLoadTimer > 0.0f || DiveTimer > 0.0f;
			if (bExplosiveGround)
			{
				if (Math::Abs(Along) > MonPeakPlant) MonPeakPlant = Math::Abs(Along);
			}
			else if (Along > MonPeakAccel) MonPeakAccel = Along;
			// The approach PLANT is scored separately, on its own band. It is the
			// most violent legal thing in the sport — an elite gather puts 3-5x
			// bodyweight through the foot and kills most of the run in ~0.16s, so
			// holding it to the same 12 m/s^2 as ordinary braking would demand
			// the game be LESS real, not more. Everything outside the gather is
			// normal locomotion and does answer to the ordinary limit.
			if (!bExplosiveGround && -Along > MonPeakDecel) MonPeakDecel = -Along;
			// 5% tolerance: ApplyMoveInput accelerates at EXACTLY the limit, and a
			// bare > counted every ordinary frame of a run as a violation. That
			// filled the diagnostic's log budget with at-the-cap noise and hid the
			// real offenders completely.
			float BudgetLimit = (Along < 0.0f) ? HumanDecelLimit : HumanAccelLimit;
			if (A.Size() > BudgetLimit * 1.05f && !bExplosiveGround)
			{
				MonAccelOverBudget += DeltaTime;
				// WHAT is producing it, not just how much. Only genuinely large
				// excursions are logged (2x the limit), for the same reason: the
				// interesting cases are velocity discontinuities, not the cap.
				if (MonAccelLogs < 25 && A.Size() > BudgetLimit * 2.0f)
				{
					MonAccelLogs++;
					Log("ACCELSPIKE " + GetName()
						+ " a=" + int(A.Size() / 100.0f)
						+ " dt=" + int(DeltaTime * 1000.0f)
						+ " v=" + int(V.Size()) + " prev=" + int(MonPrevVelBio.Size())
						+ " dive=" + (DiveTimer > 0.0f ? 1 : 0)
						+ " recover=" + (DiveRecoverTimer > 0.0f ? 1 : 0)
						+ " hit=" + int(CurrentHit));
				}
			}
		}
		MonPrevVelBio = V;

		FVector Pelvis = Mesh.GetBoneTransform(n"pelvis").Translation;
		if (bIsGrounded)
		{
			// Hip height while standing still is the reference the jump and the
			// running oscillation are both measured against.
			if (V.Size() < 30.0f) { MonStandHipZ = Pelvis.Z; MonStandActorZ = GetActorLocation().Z; }
			// GAIT bob only. The first version measured raw hip height while
			// running and read 28-112cm against a 4-6cm target, which looked like
			// a catastrophic failure but was really a broken measurement: the
			// crouch system raises and lowers the hips by up to 35cm on purpose,
			// and that dwarfs the few centimetres a stride contributes. Sampling
			// only while the crouch is HOLDING still separates the two — what is
			// left is the gait's own oscillation, which is what the target
			// describes.
			float CrouchRateNow = Math::Abs(SmCrouch - MonPrevCrouchBio) / DeltaTime;
			if (V.Size() > 150.0f && CrouchRateNow < 0.15f && DiveTimer <= 0.0f
				&& DiveRecoverTimer <= 0.0f)
			{
				// Measure the hips RELATIVE TO THE CAPSULE, not in world space:
				// absolute pelvis Z also contains the actor's own vertical travel.
				//
				// And measure it over a STRIDE-LENGTH WINDOW, not the whole rally.
				// Bob is a fast oscillation riding on top of slow stance drift; a
				// rally-long min/max reports the drift (a player rising out of a
				// deep dig and settling again) and calls it bob, which is what
				// kept this reading ~78cm against a 4-6cm target however the
				// crouch was gated. Only the largest single-window swing counts.
				float HipRel = Pelvis.Z - GetActorLocation().Z;
				// Reject a not-yet-posed mesh, whose pelvis reads at the origin
				// and lands ~90cm from the capsule. Left in, a single such frame
				// makes one window swing the height of the whole body — which is
				// exactly the ~79cm this metric kept reporting. Same guard as the
				// foot targets in PlayerIK use, for the same reason.
				if (HipRel > -45.0f && HipRel < 20.0f)
				{
					if (HipRel < MonPelvisZMin) MonPelvisZMin = HipRel;
					if (HipRel > MonPelvisZMax) MonPelvisZMax = HipRel;
				}
				MonBobWindow += DeltaTime;
				if (MonBobWindow >= BobWindowSecs)
				{
					float Swing = MonPelvisZMax - MonPelvisZMin;
					if (Swing > MonBobWorst) MonBobWorst = Swing;
					MonBobWindow = 0.0f;
					MonPelvisZMin = 99999.0f;
					MonPelvisZMax = -99999.0f;
				}
			}
		}
		else
		{
			// AIRBORNE BALLISTIC CHECK: once the feet leave the sand the only
			// thing acting on the body is gravity. Any other vertical
			// acceleration is the animation or the IK shoving the hips around,
			// which is exactly the kind of unphysical motion the eye reads as
			// floaty or robotic but no per-frame smoothness metric can see.
			// Skip the first airborne frame: MonPrevAirVz still holds the grounded
			// sentinel, and differencing against it would be meaningless.
			if (MonPrevAirVz > -99998.0f)
			{
				float VertAcc = (PlayerVelocity.Z - MonPrevAirVz) / DeltaTime;
				MonAirBallisticErr += Math::Abs(VertAcc - Gravity);
				MonAirSamples += 1.0f;
			}
			// Jump height off the CAPSULE, not the pelvis. The pelvis carries the
			// crouch, so the reference height depended on how deep the player
			// happened to be squatting when they were last still — which made a
			// jump out of a deep gather measure 159cm, taller than the player.
			// The capsule is the physics body: its rise IS the jump.
			if (MonStandActorZ > 0.0f)
			{
				float Rise = GetActorLocation().Z - MonStandActorZ;
				if (Rise > MonJumpApex) MonJumpApex = Rise;
			}
		}
		MonPrevAirVz = bIsGrounded ? -99999.0f : PlayerVelocity.Z;
		MonPrevCrouchBio = SmCrouch;
	}
	private float MonPrevAirVz = -99999.0f;
	private float MonPrevCrouchBio = 0.0f;
	private int MonAccelLogs = 0;
	// Roughly one stride at running cadence (2.5-3.5 Hz), so a window holds a
	// full up-down cycle without spanning a change of stance.
	const float BobWindowSecs = 0.4f;
	private float MonBobWindow = 0.0f;
	private float MonBobWorst = 0.0f;

	// How bent one knee is, as a 0..100 "shortening" percentage rather than an
	// angle: a straight leg spans exactly thigh+shin from hip to ankle, and any
	// bend pulls the ankle closer to the hip. 0 = locked straight, ~30 = a deep
	// squat. Deliberately NOT an arccos of the joint angle — no trig function is
	// bound in this fork (Math::Acos does not exist), and Size() alone gives a
	// monotonic, unit-free measure of the same thing, which is all the buckets
	// below compare.
	private float KneeBend(FName Thigh, FName Calf, FName Foot) const
	{
		FVector Hip = Mesh.GetBoneTransform(Thigh).Translation;
		FVector Knee = Mesh.GetBoneTransform(Calf).Translation;
		FVector Ankle = Mesh.GetBoneTransform(Foot).Translation;
		float Straight = (Knee - Hip).Size() + (Ankle - Knee).Size();
		if (Straight < 1.0f) return 0.0f;
		float Span = (Ankle - Hip).Size();
		return Math::Clamp((1.0f - Span / Straight) * 100.0f, 0.0f, 100.0f);
	}

	// Called by the AI whenever it commands a movement target. Reporting the same
	// target twice in a frame is harmless (delta 0), so both MoveToHold and
	// MoveToward2D can call it without double counting.
	void ReportMoveGoal(FVector Goal)
	{
		// Goal churn measured the SAME way as body churn: path against extent,
		// not a per-step threshold.
		//
		// A step threshold cannot tell tracking from churn, and both directions
		// of that failure have now been observed. At 150cm it missed the whole
		// 25-150 band that MoveToward2D acts on. Dropped to 40 it fired 303
		// times across 29 rallies on runs whose bodies were provably straight —
		// because a ball at 900 cm/s legitimately moves its predicted contact
		// ~100cm between 9Hz AI ticks. That is the goal FOLLOWING the ball, which
		// is the correct behaviour, not a teleport.
		//
		// Path/extent separates them with no threshold at all: a goal sweeping
		// after a ball scores ~1 however fast it sweeps, and a goal alternating
		// between two points scores 2 per cycle however small the gap.
		if (bMonGoalInit)
		{
			MonGoalPath += (Goal - MonPrevGoal).Size2D();
			float R = (Goal - MonGoalStart).Size2D();
			if (R > MonGoalExtent) MonGoalExtent = R;
		}
		else
		{
			MonGoalStart = Goal;
		}
		MonPrevGoal = Goal;
		bMonGoalInit = true;
	}

	private float KneeWalkMean() const
	{
		return (MonKneeWalkSamples > 0.0f) ? MonKneeWalkSum / MonKneeWalkSamples : 0.0f;
	}

	private float KneeStillMean() const
	{
		return (MonKneeStillSamples > 0.0f) ? MonKneeStillSum / MonKneeStillSamples : 0.0f;
	}

	// Emitted per rally from GameMode.LogRallyEnd — one greppable regression
	// number per player instead of "eyeball the flipbook".
	// DIAG: touches my team has made in this rally. Serve reception is 0 — the
	// one situation identical in the builds being compared.
	private int TeamTouchCount() const
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS == nullptr) return 0;
		return (GS.LastTouchTeam == TeamSide) ? GS.TouchesThisRally : 0;
	}

	private void SlideAdd(TArray<int>& Hist, float V)
	{
		if (Hist.Num() != SlideBuckets) { Hist.Empty(); Hist.SetNum(SlideBuckets); }
		int B = int(Math::Abs(V) / SlideBucketCm);
		if (B >= SlideBuckets) B = SlideBuckets - 1;
		Hist[B] += 1;
	}

	private int SlideP90(const TArray<int>& Hist) const
	{
		int Total = 0;
		for (int i = 0; i < Hist.Num(); i++) Total += Hist[i];
		if (Total == 0) return 0;
		int Want = int(Total * 0.9f);
		int Seen = 0;
		for (int i = 0; i < Hist.Num(); i++)
		{
			Seen += Hist[i];
			if (Seen >= Want) return int((i + 1) * SlideBucketCm);
		}
		return int(SlideBuckets * SlideBucketCm);
	}

	void EmitMotionStats()
	{
		if (!bMonitorMotion) return;
		int YawMean = (MonYawRateSamples > 0.0f) ? int(MonYawRateSum / MonYawRateSamples) : 0;
		Log("MOTIONSTATS " + GetName()
			+ " moving=" + int(MonMovingTime * 100.0f)
			+ " moveFlips=" + MonTotMoveFlips
			+ " yawFlips=" + MonTotYawFlips
			+ " crouchFlips=" + MonTotCrouchFlips
			+ " ikTeleports=" + MonTotIKTeleports
			+ " handJerks=" + MonTotHandJerks
			+ " handTurnMax=" + int(MonHandTurnMax)
			+ " gestureT=" + int(MonHandGestureTime * 100.0f)
			+ " goalJumps=" + MonGoalJumps
			+ " yawRateMean=" + YawMean
			+ " yawRateMax=" + int(MonYawRateMax)
			+ " wasteWorst=" + int(MonWasteWorst)
			+ " wasteTotal=" + int(MonWasteTotal)
			+ " yawRevisit=" + int(MonYawRevisit)
			+ " yawWasteDeg=" + int(MonYawWaste)
			+ " yawWasteRate=" + int(MonYawWasteStill / Math::Max(MonYawStillSecs, 0.001f) * 10.0f)
			+ " crouchRevisit=" + int(MonCrRevisit)
			+ " footSlide=" + int(MonFootSlide)
			+ " pelvisFlips=" + MonPelvisFlips
			+ " kneeWalk=" + int(KneeWalkMean())
			+ " kneeWalkMin=" + int(MonKneeWalkMin < 900.0f ? MonKneeWalkMin : 0.0f)
			+ " kneeWalkMax=" + int(MonKneeWalkMax)
			+ " kneeWalkTravel=" + int(MonKneeWalkTravel)
			+ " kneeOpp=" + int(MonKneeOppTravel)
			+ " kneeStill=" + int(KneeStillMean())
			+ " kneeStillMax=" + int(MonKneeStillMax)
			+ " legAlpha=" + int((Anim != nullptr ? Anim.LegIKAlpha : 0.0f) * 100.0f)
			+ " underSand=" + int(MonUnderSandTime * 100.0f)
			+ " backpedal=" + int(MonBackpedalTime * 100.0f)
			+ " turnRun=" + int(MonTurnRunTime * 100.0f)
			+ " footZMin=" + int(MonFootZMin)
			+ " kneeZMin=" + int(MonKneeZMin)
			+ " pelvSlideX=" + SlideP90(MonSlideHistX)
			+ " pelvSlideY=" + SlideP90(MonSlideHistY)
			+ " pelvSlideZ=" + SlideP90(MonSlideHistZ)
			// RAW COUNTS, not a per-rally ratio. Emitted as a percentage first,
			// this read 100% on every run and said nothing: the denominator is
			// one or two bookings per rally, so a single unmakeable one pins the
			// ratio at 100, and the report's max() then finds such a rally every
			// time. Summed across the run it is a real rate — and the number it
			// gives is 12% of the bookings that actually become contacts, not
			// the 70% the broken version implied.
			+ " planBookings=" + MonPlanBookings
			+ " planInfeas=" + MonPlanInfeasible);

		// Absolute plausibility, separate from the relative numbers above so a
		// regression comparison never gets mixed up with a physics verdict.
		// Units converted to m/s^2 and cm here, at the boundary, once.
		float BobCm = MonBobWorst;
		int AirErr = (MonAirSamples > 0.0f) ? int(MonAirBallisticErr / MonAirSamples) : 0;
		Log("BIOMECH " + GetName()
			+ " accel=" + int(MonPeakAccel / 100.0f)          // m/s^2, human <= 10
			+ " decel=" + int(MonPeakDecel / 100.0f)          // m/s^2, human <= 12
			+ " plant=" + int(MonPeakPlant / 100.0f)          // m/s^2, approach gather 20-45
			+ " overBudget=" + int(MonAccelOverBudget * 100.0f)  // centiseconds outside the band
			+ " bob=" + int(BobCm)                            // cm, running 4-6
			+ " airErr=" + AirErr                             // cm/s^2 off pure ballistic, want 0
			+ " jump=" + int(MonJumpApex)                     // cm hip rise, elite spike 60-90
			+ " topSpeed=" + int(MonTopSpeed / 100.0f));      // m/s, sand sprint <= 8

		MonPeakAccel = 0.0f;
		MonPeakDecel = 0.0f;
		MonPeakPlant = 0.0f;
		MonAccelOverBudget = 0.0f;
		MonPelvisZMin = 99999.0f;
		MonPelvisZMax = -99999.0f;
		MonBobWorst = 0.0f;
		MonBobWindow = 0.0f;
		MonAirBallisticErr = 0.0f;
		MonAirSamples = 0.0f;
		MonJumpApex = 0.0f;
		MonTopSpeed = 0.0f;
		MonTotMoveFlips = 0;
		MonTotYawFlips = 0;
		MonTotCrouchFlips = 0;
		MonTotIKTeleports = 0;
		MonGoalJumps = 0;
		MonMovingTime = 0.0f;
		MonYawRateSum = 0.0f;
		MonYawRateSamples = 0.0f;
		MonYawRateMax = 0.0f;
		MonFootSlide = 0.0f;
		MonSlideHistX.Empty(); MonSlideHistX.SetNum(SlideBuckets);
		MonSlideHistY.Empty(); MonSlideHistY.SetNum(SlideBuckets);
		MonSlideHistZ.Empty(); MonSlideHistZ.SetNum(SlideBuckets);
		MonPlanBookings = 0;
		MonPlanInfeasible = 0;
		MonPelvisFlips = 0;
		MonWasteWorst = 0.0f;
		MonWasteTotal = 0.0f;
		MonKneeWalkSum = 0.0f;
		MonKneeWalkSamples = 0.0f;
		MonKneeWalkMax = 0.0f;
		MonKneeWalkMin = 999.0f;
		MonKneeStillSum = 0.0f;
		MonKneeStillSamples = 0.0f;
		MonKneeStillMax = 0.0f;
		MonKneeWalkTravel = 0.0f;
		MonKneeOppTravel = 0.0f;
		bMonKneeOppInit = false;
		MonUnderSandTime = 0.0f;
		MonBackpedalTime = 0.0f;
		MonTurnRunTime = 0.0f;
		MonFootZMin = 9999.0f;
		MonKneeZMin = 9999.0f;
		MonPoseLogs = 0;
	}

	private void UpdateMotionMonitor(float DeltaTime)
	{
		// Compensation: how far the solver moved the pelvis off the script's
		// target. Outside the monitor's own trace gate on purpose — this is a
		// shipped metric, not a diagnostic.
		if (Mesh != nullptr && Anim != nullptr && Anim.LegIKAlpha > 0.95f)
		{
			FVector Slip = Mesh.GetBoneTransform(n"pelvis").Location - Anim.PelvisTarget;
			SlideAdd(MonSlideHistX, Slip.X);
			SlideAdd(MonSlideHistY, Slip.Y);
			SlideAdd(MonSlideHistZ, Slip.Z);
		}
		if (!bMonitorMotion || DeltaTime <= 0.0f) return;
		UpdateBiomech(DeltaTime);
		UpdateWastedTravel(DeltaTime);
		float Yaw = GetActorRotation().Yaw;
		float CrouchNow = (Anim != nullptr) ? Anim.CrouchAmount : 0.0f;
		FVector HandR = (Anim != nullptr) ? Anim.HandTargetR : FVector::ZeroVector;
		UpdateRotRevisit(DeltaTime, Yaw, CrouchNow);

		// WAVEFORM TRACE. A ratio can say "this oscillates" but never "at what
		// frequency, at what amplitude, driven by which source" — and guessing
		// the answer from a ratio has now cost one wrong fix. One line per player
		// per frame; scripts/shake_scope.py reconstructs the signal, finds the
		// dominant frequency per channel, and reports which facing source was
		// selected while it happened. Diagnostic, not telemetry: off by default.
		if (bTraceMotion)
		{
			MonTraceT += DeltaTime;
			// Pelvis RELATIVE TO THE ACTOR is the decisive split, the same shape
			// as target-vs-yaw: it separates "the character moved" from "the mesh
			// moved inside the character". Script-side movement cannot appear in
			// it at all, so anything oscillating here is the anim/IK layer.
			FVector Pv = (Mesh != nullptr)
				? Mesh.GetBoneTransform(n"pelvis").Translation - GetActorLocation()
				: FVector::ZeroVector;
			// SPINE CHAIN, ABSOLUTE WORLD Z — the idle pose (crouch=0, ikAlpha=0,
			// neither the pelvis Modify Bone nor the arm IK meant to be doing
			// anything) still shows the mesh folded double: pelvis and head at
			// nearly the same height. Dumping every bone from pelvis to head
			// pinpoints WHERE the fold actually is, instead of guessing from the
			// two systems whose scripted weights say they should be off.
			float SpZ1 = 0.0f, SpZ2 = 0.0f, SpZ3 = 0.0f, NeckZ = 0.0f, HeadZ = 0.0f, PelvZ = 0.0f;
			// Forward offset of head/spine3 from the pelvis, along the actor's OWN
			// forward vector — this is the number that actually distinguishes
			// "upright" from "folded at the same height range": a fold reads as a
			// large FORWARD number here even when the Z climb alone looks normal.
			float HeadFwd = 0.0f, Sp3Fwd = 0.0f;
			if (Mesh != nullptr)
			{
				FVector FwdV = GetActorForwardVector();
				FVector PelvLoc = Mesh.GetBoneTransform(n"pelvis").Location;
				PelvZ = PelvLoc.Z;
				SpZ1 = Mesh.GetBoneTransform(n"spine_01").Location.Z;
				SpZ2 = Mesh.GetBoneTransform(n"spine_02").Location.Z;
				FVector Sp3Loc = Mesh.GetBoneTransform(n"spine_03").Location;
				SpZ3 = Sp3Loc.Z;
				NeckZ = Mesh.GetBoneTransform(n"neck_01").Location.Z;
				FVector HeadLoc = Mesh.GetBoneTransform(n"head").Location;
				HeadZ = HeadLoc.Z;
				HeadFwd = (HeadLoc - PelvLoc).DotProduct(FwdV);
				Sp3Fwd = (Sp3Loc - PelvLoc).DotProduct(FwdV);
			}
			Log("TRACE " + GetName() + " t=" + int(MonTraceT * 1000.0f)
				+ " px=" + int(Pv.X * 10.0f)
				+ " py=" + int(Pv.Y * 10.0f)
				+ " pz=" + int(Pv.Z * 10.0f)
				+ " ik=" + int(IKWeight * 100.0f)
				+ " la=" + int((Anim != nullptr ? Anim.LegIKAlpha : 0.0f) * 100.0f)
				+ " yaw=" + int(Yaw * 10.0f)
				+ " want=" + int(DbgWantYaw * 10.0f)
				+ " src=" + DbgFacingSrc
				+ " cr=" + int(CrouchNow * 1000.0f)
				+ " spd=" + int(FVector(PlayerVelocity.X, PlayerVelocity.Y, 0).Size())
				+ " hit=" + int(CurrentHit)
				+ " tt=" + TeamTouchCount()
				+ " x=" + int(GetActorLocation().X)
				+ " y=" + int(GetActorLocation().Y)
				+ " actorZ=" + int(GetActorLocation().Z)
				+ " pelvZ=" + int(PelvZ)
				+ " sp1Z=" + int(SpZ1)
				+ " sp2Z=" + int(SpZ2)
				+ " sp3Z=" + int(SpZ3)
				+ " neckZ=" + int(NeckZ)
				+ " headZ=" + int(HeadZ)
				+ " headFwd=" + int(HeadFwd)
				+ " sp3Fwd=" + int(Sp3Fwd));
		}

		if (!bMonInit)
		{
			bMonInit = true;
			MonPrevVel = PlayerVelocity;
			MonPrevYaw = Yaw;
			MonPrevCrouch = CrouchNow;
			MonPrevHandR = HandR;
			return;
		}

		// 1) Locomotion reversals: both frames moving, direction flipped.
		FVector V = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0);
		FVector PV = FVector(MonPrevVel.X, MonPrevVel.Y, 0);
		if (V.Size() > 60.0f && PV.Size() > 60.0f
			&& V.DotProduct(PV) < -0.2f * V.Size() * PV.Size())
		{
			MonMoveFlips++;
			MonTotMoveFlips++;
		}
		// Denominator: only time actually spent moving is comparable between runs.
		if (V.Size() > 60.0f) MonMovingTime += DeltaTime;

		// 2) Yaw oscillation: turn direction alternates at a real turn RATE.
		// Thresholds are rates (per second), not per-frame deltas — a per-frame
		// threshold silently under-detects at high frame rates (nullrhi runs
		// uncapped and the first detector pass saw nothing at any fps).
		float YawDelta = Math::FindDeltaAngleDegrees(MonPrevYaw, Yaw);
		float YawRate = YawDelta / DeltaTime;
		if (Math::Abs(YawRate) > 60.0f && Math::Abs(MonPrevYawDelta) > 60.0f
			&& YawRate * MonPrevYawDelta < 0.0f)
		{
			MonYawFlips++;
			MonTotYawFlips++;
			if (MonYFlipLogs < 60)
			{
				MonYFlipLogs++;
				FVector V2 = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0);
				Log("YFLIP rate=" + int(YawRate) + " prevRate=" + int(MonPrevYawDelta)
					+ " yaw=" + int(Yaw) + " src=" + DbgFacingSrc + " wantYaw=" + int(DbgWantYaw)
					+ " dt=" + DeltaTime + " prevDt=" + MonPrevDt
					+ " moveIn=(" + int(MoveInput.X * 100.0f) + "," + int(MoveInput.Y * 100.0f) + ")"
					+ " velDir=(" + int(V2.X) + "," + int(V2.Y) + ") speed=" + int(V2.Size())
					+ " hit=" + int(CurrentHit) + " grounded=" + bIsGrounded);
			}
		}
		if (Math::Abs(YawRate) > 20.0f) MonPrevYawDelta = YawRate;
		MonPrevDt = DeltaTime;
		// Turn-rate distribution: the flip COUNT says how often direction reverses,
		// this says how violently the body turns at all — the thing that reads as
		// unnatural even when the direction never reverses.
		if (Math::Abs(YawRate) > 20.0f)
		{
			MonYawRateSum += Math::Abs(YawRate);
			MonYawRateSamples += 1.0f;
			MonYawRateMax = Math::Max(MonYawRateMax, Math::Abs(YawRate));
		}

		// 3) Crouch flapping: knee direction alternates at a real rate. The
		// threshold must catch ASYMMETRIC oscillation too: the proportional
		// sink rises at gain 3, so the up-leg of a ±0.3 square wave moves at
		// ~0.9/s — a 1.0 threshold declared the visible set/bump pose bob
		// "no jitter" while Erik watched it. 0.6 catches both legs.
		float CrouchRate = (CrouchNow - MonPrevCrouch) / DeltaTime;
		if (Math::Abs(CrouchRate) > 0.6f && Math::Abs(MonPrevCrouchDelta) > 0.6f
			&& CrouchRate * MonPrevCrouchDelta < 0.0f)
		{
			MonCrouchFlips++;
			MonTotCrouchFlips++;
			// Component dump: which upstream source is alternating? (pose*blend
			// vs ExtraCrouch vs the sink itself). Capped so logs stay readable.
			if (MonCFlipLogs < 60)
			{
				MonCFlipLogs++;
				Log("CFLIP rate=" + CrouchRate + " prevRate=" + MonPrevCrouchDelta
					+ " sm=" + CrouchNow + " want=" + DbgWantCrouch
					+ " pose=" + DbgPoseCrouch + " extra=" + ExtraCrouch + " held=" + HeldCrouch
					+ " dt=" + DeltaTime + " hit=" + int(CurrentHit)
					+ " speed=" + int(FVector(PlayerVelocity.X, PlayerVelocity.Y, 0).Size()));
			}
		}
		if (Math::Abs(CrouchRate) > 0.3f) MonPrevCrouchDelta = CrouchRate;

		// 4) IK-sink violation: the hand target moved faster than the sink's
		// speed limit allows — something writes past the anti-flicker sink.
		// The ceiling follows SinkBoostLog: a swing legitimately opens it.
		float HandStep = (HandR - MonPrevHandR).Size();
		if (HandStep > 900.0f * SinkBoostLog * DeltaTime * 1.6f + 2.0f)
		{
			MonIKTeleports++;
			MonTotIKTeleports++;
		}
		// 4b) HAND JERK during a hit gesture: the step direction reversing hard
		// between frames, with real movement on both sides of the reversal so a
		// hand that is merely settling cannot register. Both magnitudes are in
		// cm per frame; 1.5 at 120Hz is 180cm/s, i.e. deliberate motion.
		FVector HandStepVec = HandR - MonPrevHandR;
		if (bReaching && DeltaTime > 0.0f)
		{
			MonHandGestureTime += DeltaTime;
			if (bMonHandStepInit && HandStepVec.Size() > 1.5f && MonPrevHandStep.Size() > 1.5f)
			{
				float CosT = HandStepVec.GetSafeNormal()
					.DotProduct(MonPrevHandStep.GetSafeNormal());
				float TurnDeg = Math::RadiansToDegrees(Math::Acos(Math::Clamp(CosT, -1.0f, 1.0f)));
				if (TurnDeg > MonHandTurnMax) MonHandTurnMax = TurnDeg;
				if (TurnDeg > 90.0f)
				{
					MonHandJerks++;
					MonTotHandJerks++;
					if (MonJerkLogs < 40)
					{
						MonJerkLogs++;
						Log("HANDJERK turn=" + int(TurnDeg) + " hit=" + int(CurrentHit)
							+ " step=" + int(HandStepVec.Size() * 100)
							+ " prev=" + int(MonPrevHandStep.Size() * 100)
							+ " swing=" + int(SwingProgress() * 100)
							+ " grounded=" + bIsGrounded
							// The platform hangs off the chest frame (ChestMid +
							// direction * reach), so a rotating or translating
							// body swings the hands with it. Record both, or the
							// arm gets blamed for the body's motion.
							+ " yawRate=" + int(YawRate)
							+ " bodySpd=" + int(FVector(PlayerVelocity.X, PlayerVelocity.Y, 0).Size()));
					}
				}
			}
			MonPrevHandStep = HandStepVec;
			bMonHandStepInit = true;
		}
		else
			bMonHandStepInit = false;

		// Rolling hand-speed peak for the SWING telemetry (decays ~0.5s).
		PeakHandSpd = Math::Max(HandStep / DeltaTime, PeakHandSpd - 4000.0f * DeltaTime);

		// 5) What the solver actually produced this frame.
		if (Mesh != nullptr)
		{
			FVector FootL = Mesh.GetBoneTransform(n"foot_l").Translation;
			FVector FootR = Mesh.GetBoneTransform(n"foot_r").Translation;
			FVector Pelvis = Mesh.GetBoneTransform(n"pelvis").Translation;

			if (!bMonBoneInit)
			{
				bMonBoneInit = true;
				MonPrevFootL = FootL;
				MonPrevFootR = FootR;
				MonPrevPelvis = Pelvis;
			}
			else if (bIsGrounded)
			{
				// A foot counts as planted when it is within 12cm of the sand.
				// Horizontal travel while planted is slide, in cm.
				float FloorPlant = FloorZ + 12.0f;
				if (FootL.Z < FloorPlant)
					MonFootSlide += FVector(FootL.X - MonPrevFootL.X, FootL.Y - MonPrevFootL.Y, 0).Size();
				if (FootR.Z < FloorPlant)
					MonFootSlide += FVector(FootR.X - MonPrevFootR.X, FootR.Y - MonPrevFootR.Y, 0).Size();

				// Pelvis reversals, measured the same rate-based way as the rest:
				// the hips flipping direction at frame rate is the "shaky" look
				// even when velocity and yaw are both perfectly smooth.
				FVector PVel = (Pelvis - MonPrevPelvis) / DeltaTime;
				if (PVel.Size() > 40.0f && MonPrevPelvisVel.Size() > 40.0f
					&& PVel.DotProduct(MonPrevPelvisVel) < -0.2f * PVel.Size() * MonPrevPelvisVel.Size())
					MonPelvisFlips++;
				if (PVel.Size() > 15.0f) MonPrevPelvisVel = PVel;
			}

			// Knee flexion, bucketed by whether we are actually walking. 100 cm/s
			// sits above MoveToHold's idle jitter but well below a real run, so
			// "walk" means a gait clip is genuinely playing.
			if (bIsGrounded)
			{
				float KneeL = KneeBend(n"thigh_l", n"calf_l", n"foot_l");
				float KneeR = KneeBend(n"thigh_r", n"calf_r", n"foot_r");
				float KneeAvg = (KneeL + KneeR) * 0.5f;
				float Spd2D = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0).Size();
				if (Spd2D > 100.0f)
				{
					MonKneeWalkSum += KneeAvg;
					MonKneeWalkSamples += 1.0f;
					if (KneeAvg > MonKneeWalkMax) MonKneeWalkMax = KneeAvg;
					if (KneeAvg < MonKneeWalkMin) MonKneeWalkMin = KneeAvg;
					if (MonPrevKneeL >= 0.0f)
						MonKneeWalkTravel += Math::Abs(KneeL - MonPrevKneeL);
				}
				else
				{
					MonKneeStillSum += KneeAvg;
					MonKneeStillSamples += 1.0f;
					if (KneeAvg > MonKneeStillMax) MonKneeStillMax = KneeAvg;
				}
				MonPrevKneeL = KneeL;

				FVector KL = Mesh.GetBoneTransform(n"calf_l").Translation;
				FVector KR = Mesh.GetBoneTransform(n"calf_r").Translation;
				float KneeOpp = (KL - GetActorLocation()).DotProduct(GetActorForwardVector())
					- (KR - GetActorLocation()).DotProduct(GetActorForwardVector());
				if (Spd2D > 80.0f)
				{
					if (bMonKneeOppInit)
						MonKneeOppTravel += Math::Abs(KneeOpp - MonPrevKneeOpp);
					bMonKneeOppInit = true;
					MonPrevKneeOpp = KneeOpp;
				}

				// Per-frame trace on ONE player while walking: the rally totals say
				// the knees stay locked but not WHY. Prints the whole leg chain so
				// the pelvis/foot relationship is visible frame by frame.
				if (bKneeTrace && Spd2D > 100.0f && MonKneeTraceLogs < 120)
				{
					MonKneeTraceLogs++;
					FVector HipL = Mesh.GetBoneTransform(n"thigh_l").Translation;
					FVector AnkL = Mesh.GetBoneTransform(n"foot_l").Translation;
					FVector KneeLoc = Mesh.GetBoneTransform(n"calf_l").Translation;
					// Segment lengths are constant (43 + 42 = 85cm) — printed so a
					// suspicious knee reading can be told apart from a broken
					// measurement. span == 85 means the leg is dead straight.
					Log("KNEESEG thighLen=" + int((KneeLoc - HipL).Size())
						+ " shinLen=" + int((AnkL - KneeLoc).Size())
						+ " span=" + int((AnkL - HipL).Size())
						+ " hipZ=" + int(HipL.Z) + " kneeZ=" + int(KneeLoc.Z) + " ankZ=" + int(AnkL.Z));
					Log("KNEETRACE " + GetName()
						+ " spd=" + int(Spd2D)
						+ " kneeL=" + int(KneeL) + " kneeR=" + int(KneeR)
						+ " fwdL=" + int((KL - GetActorLocation()).DotProduct(GetActorForwardVector()))
						+ " fwdR=" + int((KR - GetActorLocation()).DotProduct(GetActorForwardVector()))
						+ " legAlpha=" + int((Anim != nullptr ? Anim.LegIKAlpha : 0.0f) * 100.0f)
						+ " crouch=" + int(SmCrouch * 100.0f)
						+ " pelvisZ=" + int(Pelvis.Z)
						+ " hipLZ=" + int(HipL.Z)
						+ " ankLZ=" + int(AnkL.Z)
						+ " actorZ=" + int(GetActorLocation().Z)
						+ " tgtLZ=" + int(Anim != nullptr ? Anim.FootTargetL.Z : 0.0f)
						+ " tgtPelZ=" + int(Anim != nullptr ? Anim.PelvisTarget.Z : 0.0f)
						+ " hipAnkDist=" + int((AnkL - HipL).Size()));
				}
			}
			MonPrevFootL = FootL;
			MonPrevFootR = FootR;
			MonPrevPelvis = Pelvis;

			// --- POSE anomaly sampling (feet under sand / bent-forward backpedal)
			FVector KneeBoneL = Mesh.GetBoneTransform(n"calf_l").Translation;
			FVector KneeBoneR = Mesh.GetBoneTransform(n"calf_r").Translation;
			float FootMinZ = Math::Min(FootL.Z, FootR.Z);
			float KneeMinZ = Math::Min(KneeBoneL.Z, KneeBoneR.Z);
			if (FootMinZ < MonFootZMin) MonFootZMin = FootMinZ;
			if (KneeMinZ < MonKneeZMin) MonKneeZMin = KneeMinZ;
			const float SoleZ = FloorZ + 2.0f;   // ankle rest is ~3–6; <2 = buried
			float HSpdPose = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0).Size();
			float FwdSpd = (Anim != nullptr) ? Anim.ForwardSpeed : 0.0f;
			if (bIsGrounded && FootMinZ < SoleZ)
				MonUnderSandTime += DeltaTime;
			if (HSpdPose > 80.0f && FwdSpd < -40.0f)
				MonBackpedalTime += DeltaTime;
			if (bTurnRun)
				MonTurnRunTime += DeltaTime;

			if (MonPoseLogCooldown > 0.0f) MonPoseLogCooldown -= DeltaTime;
			bool bUnder = bIsGrounded && FootMinZ < SoleZ;
			bool bBack = HSpdPose > 120.0f && FwdSpd < -80.0f;
			if ((bUnder || bBack) && MonPoseLogCooldown <= 0.0f && MonPoseLogs < 240)
			{
				MonPoseLogs++;
				MonPoseLogCooldown = 0.12f;
				Log("POSE " + GetName()
					+ " footZ=" + int(FootMinZ)
					+ " kneeZ=" + int(KneeMinZ)
					+ " pelvisZ=" + int(Pelvis.Z)
					+ " actorZ=" + int(GetActorLocation().Z)
					+ " fwd=" + int(FwdSpd)
					+ " spd=" + int(HSpdPose)
					+ " turnRun=" + (bTurnRun ? 1 : 0)
					+ " crouch=" + int(SmCrouch * 100.0f)
					+ " legA=" + int((Anim != nullptr ? Anim.LegIKAlpha : 0.0f) * 100.0f)
					+ " hitA=" + int((Anim != nullptr ? Anim.HitAlpha : 0.0f) * 100.0f)
					+ " dive=" + (IsDiving() ? 1 : 0)
					+ " ground=" + (bIsGrounded ? 1 : 0)
					+ " tgtFZ=" + int(Anim != nullptr ? Math::Min(Anim.FootTargetL.Z, Anim.FootTargetR.Z) : 0)
					+ " under=" + (bUnder ? 1 : 0)
					+ " back=" + (bBack ? 1 : 0));
			}
		}

		MonPrevVel = PlayerVelocity;
		MonPrevYaw = Yaw;
		MonPrevCrouch = CrouchNow;
		MonPrevHandR = HandR;

		MonWindow += DeltaTime;
		if (MonWindow >= 0.5f)
		{
			// The window's own wasted travel, so the emit condition can see the
			// thing the three flip counters structurally cannot. 25cm of walking
			// that arrives nowhere inside half a second is a shuttle, not a run.
			float WinExtent = Math::Max(MonWasteExtent, 1.0f);
			float WinRatio = (MonWastePath >= WasteMinPath) ? MonWastePath / WinExtent : 1.0f;
			// Same primitive for the commanded goal. 25cm floor for the same
			// reason: below it the extent is noise and the ratio is meaningless.
			float GoalRatio = (MonGoalPath >= 25.0f)
				? MonGoalPath / Math::Max(MonGoalExtent, 1.0f) : 1.0f;
			if (int(GoalRatio * 100.0f) > MonGoalJumps) MonGoalJumps = int(GoalRatio * 100.0f);
			if (MonMoveFlips >= 2 || MonYawFlips >= 3 || MonCrouchFlips >= 3
				|| MonIKTeleports >= 1 || WinRatio > 2.5f || GoalRatio > 2.5f
				|| MonYawRevisitWin > 250.0f || MonCrRevisitWin > 250.0f)
			{
				Log("JITTER team=" + int(TeamSide)
					+ " revisit=" + int(WinRatio * 100.0f)
					+ " yawRevisit=" + int(MonYawRevisitWin)
					+ " crouchRevisit=" + int(MonCrRevisitWin)
					+ " goalChurn=" + int(GoalRatio * 100.0f)
					+ " moveFlips=" + MonMoveFlips
					+ " yawFlips=" + MonYawFlips
					+ " crouchFlips=" + MonCrouchFlips
					+ " ikTeleports=" + MonIKTeleports
					+ " speed=" + int(FVector(PlayerVelocity.X, PlayerVelocity.Y, 0).Size())
					+ " hit=" + int(CurrentHit)
					+ " grounded=" + bIsGrounded);
			}
			MonGoalPath = 0.0f;
			MonGoalExtent = 0.0f;
			MonGoalStart = MonPrevGoal;
			MonWindow = 0.0f;
			MonMoveFlips = 0;
			MonYawFlips = 0;
			MonCrouchFlips = 0;
			MonIKTeleports = 0;
		}
	}

	// ANTI-FLICKER SINK STATE: everything the ABP sees is speed-limited at the
	// single write point (end of UpdateIKTargets). Public: the mixin owns them.
	// Effector VELOCITIES, so the sink can limit acceleration and not just speed
	// (see MoveTowardAccel in PlayerIK). New members — a full reload, not a soft
	// one, is needed to pick these up in the editor.
	// Last well-conditioned platform bearing (see the bump branch in PlayerIK).
	FVector SmPlatDir;
	FVector SmHandVelR;
	FVector SmHandVelL;
	FVector SmHandR;
	FVector SmHandL;
	FVector SmPoleR;
	FVector SmPoleL;
	FRotator SmRotR;
	FRotator SmRotL;
	float SmCrouch = 0.0f;
	bool bSmInit = false;

	// FOOT YAW-LAG FIX: the echoed foot IK target is rotated by the actor's
	// frame-to-frame yaw change before reuse — see UpdateIKTargets. Public:
	// the mixin owns them.
	float PrevYawForFeet = 0.0f;
	bool bFootYawInit = false;

	// Extra crouch (0..1) from FRAME-RATE transient envelopes (split step, dive,
	// jump load, landing absorb, air tuck). Written by Max every frame while the
	// envelope is active; decays every frame (top of UpdatePlayer) so it releases
	// the instant the envelope ends. Combined with HeldCrouch by Max in the IK.
	float ExtraCrouch = 0.0f;

	// Extra crouch (0..1) from the AI's TICK-RATE stance requests (RequestCrouch:
	// ready stance, planted wait, block track, defensive base). The AI only
	// re-asserts every ReactionDelay, so this is HELD across the gap (CrouchHoldTimer)
	// and only decays once the AI stops asking — separate lifetime from the
	// per-frame transients so a transient peak can't get frozen at the held rate.
	float HeldCrouch = 0.0f;

	// Landing absorption state (knees flex on touchdown, see UpdatePlayer).
	private float LandAbsorbTimer = 0.0f;
	private float LandAbsorbDepth = 0.5f;

	// AI sets this while preparing to play the ball, with the hit type it
	// intends, so the arms extend toward the ball before contact. Requests are
	// held for a beat (not cleared per-frame) because the AI only re-asserts
	// every ReactionDelay — clearing each frame made poses sawtooth between ticks.
	bool bReaching = false;
	// Where this reach is aimed (world). Set by Reach(), lapses with it.
	FVector ReachContact = FVector::ZeroVector;
	bool bHasReachContact = false;
	private float ReachHoldTimer = 0.0f;
	private float CrouchHoldTimer = 0.0f;

	// SECONDS UNTIL THE CONTACT THIS REACH IS AIMED AT — the other half of the
	// handover above. 99 = "nobody told me", which every pose falls back from.
	//
	// The planner starts the gesture MB_GestureLead (1.15s) before contact, and
	// until this existed the arms had no way to know that: they snapped into the
	// final contact shape the frame the AI decided on the stroke and then stood
	// perfectly still for the best part of a second waiting for the ball. That
	// is what "de har inga förberedande rörelser" was — not a missing animation,
	// but a whole second of lead time the poses never spent. It ticks down every
	// frame (the AI only re-asserts at ~9Hz; a 9Hz staircase driving hand targets
	// is exactly the class of jerk the sink exists to civilise).
	float ReachTau = 99.0f;
	// THE MEET POINT THE HANDS ACTUALLY FOLLOW — ReachContact eased, not snapped.
	//
	// The AI re-plans at its reaction cadence (~9Hz) and hands over a fresh
	// Plan.Contact each time, so the raw point STEPS: measured while the platform
	// was parked inside 30cm, the meet point moved 0.38cm in a median frame but
	// 8.9cm at p90 — the tick frames. The platform turns a step of the meet point
	// into 2.45x that at the hand (it is placed by the BEARING to the point,
	// walked out 72cm), so a 9cm re-plan became a 22cm hand jump for the sink to
	// absorb. Fighting the amplification was the wrong end: the fix is to stop
	// the input from stepping.
	//
	// THE TIME CONSTANT IS SHORT, AND THAT IS MEASURED. 0.08s looked obviously
	// right — it steadied the parked platform tenfold (median step 0.70cm ->
	// 0.06) — and cost hand reversals 0.110 -> 0.138 per gesture-second, because
	// an eased point that is still catching up when the swing fires is one more
	// thing for the stroke to turn around. 0.035 keeps most of the steadiness
	// (0.24cm) at 0.116, i.e. back inside the baseline's noise. Steadier input
	// is only worth having while the hand is not paying for the lag.
	FVector SmReachContact = FVector::ZeroVector;
	private bool bSmReachInit = false;
	const float ReachEaseTime = 0.035f;
	// 0 when the gesture began, 1 at the contact it was started for.
	//
	// MONOTONE within a gesture, and that is the point: a wind-up never un-winds.
	// ReachTau is a re-prediction, so it wobbles; feeding that wobble straight
	// into the hand targets would let the arms walk backwards down their own
	// preparation. Reset when the gesture releases (see the Blend<0.05
	// passthrough in PlayerIK) and when Reach picks a different stroke.
	float GestureClock = 0.0f;

	// THE ONE CONTACT POINT. Whoever asks for the reach also says WHERE the
	// contact is, because they already know: the AI hands over Plan.Contact,
	// the point its feet are walking to, solved by the interpolated
	// Predict::BallTimeToHeight at the height ContactHeightFor() picked for this
	// stroke.
	//
	// This replaces a second, independent prediction that lived on the pawn
	// (PredictBallCrossZ -> PredictedMeetLow/High, deleted with this change).
	// The engine had THREE answers to "where does the ball cross height Z" —
	// Ball::PredictLanding, Predict::BallTimeToHeight and that one — three step
	// sizes, and the same first-sample-past-the-crossing defect was found and
	// fixed in two of them months apart while the third sat unnoticed, feeding
	// the hands a sawtooth that the full-body IK's root pre-pull wrote into the
	// pelvis. That was "de skakar innan varje bagger".
	//
	// So the hands no longer estimate the meet point at all. They aim exactly
	// where the feet are already going, at decision rate rather than frame rate.
	void Reach(EHitType Type, FVector Contact, float Tau = 99.0f)
	{
		bReaching = true;
		ReachHoldTimer = 0.25f;
		bHasReachContact = Contact.SizeSquared() > 1.0f;
		if (bHasReachContact) ReachContact = Contact;
		// ...and WHEN, because the planner already knows. See ReachTau.
		if (Tau < 90.0f) ReachTau = Math::Max(Tau, 0.0f);
		if (HitAnimTimer > 0.0f) return;   // don't override an active swing
		if (Type != CurrentHit)
		{
			// ANTI-FLICKER: a gesture must live MinGestureDwell before another
			// may replace it — two systems disagreeing about the stroke at
			// different rates alternated IK branches per frame. Real contacts
			// (TriggerHit) bypass this: they're events, not opinions.
			if (GestureAge < MinGestureDwell) return;
			CurrentHit = Type;
			GestureAge = 0.0f;
			GestureClock = 0.0f;
		}
	}

	// Age of the current gesture type; guards against per-frame branch flips.
	private float GestureAge = 10.0f;
	const float MinGestureDwell = 0.15f;

	// Crouch request that survives between AI reaction ticks (ready stance etc.).
	// Per-frame writers (split step, dive) set ExtraCrouch directly instead — this
	// channel is HELD across the tick gap; theirs decays every frame.
	void RequestCrouch(float Amount)
	{
		HeldCrouch = Math::Max(HeldCrouch, Amount);
		CrouchHoldTimer = 0.25f;
	}

	// 0 outside a strike, ramping 0->1 over the contact swing that TriggerHit
	// starts. The IK uses this to swing the arms THROUGH the ball along the aim
	// at contact — a static contact pose reads as catching, not hitting.
	float SwingProgress() const
	{
		if (HitAnimTimer <= 0.0f || HitAnimDuration <= 0.0f) return 0.0f;
		return 1.0f - Math::Clamp(HitAnimTimer / HitAnimDuration, 0.0f, 1.0f);
	}

	// Serve choreography phase (0 = idle, ramps 0->1 through toss + strike).
	// Driven by the AI serve sequence; read by the Hit_Serve branch in PlayerIK.
	float ServePhase = 0.0f;
	// The left hand's WORLD-space TARGET this frame, from the same formula the
	// FBIK is converging toward (PlayerIK's Hit_Serve branch writes this every
	// frame, unconditionally — deterministic, no animation state in it at all).
	//
	// RunServeSequence carries and releases the ball from THIS, not from
	// Mesh.GetBoneTransform(hand_l). The solved bone is downstream of the
	// whole AnimGraph — FBIK convergence speed, the hit-overlay blend, the
	// leg/pelvis Modify Bone system — and TWO SEPARATE, INDEPENDENT problems in
	// that chain were each measured to corrupt it enough to net the serve:
	// routing Hit_Serve through the spike swing clip (fixed in HitClipIndexFor)
	// and, even with that fixed, whatever 7f9b69e's HitAnimTimer gate on
	// HitAlpha does to the timing of when the bump clip (still selected as the
	// least-wrong fallback) blends in. Both routes through the same failure
	// shape: this hit type reads a live bone for gameplay, and nothing in the
	// AnimGraph is obligated to keep that bone's position deterministic frame
	// to frame. The target this script computes for the FBIK to chase IS
	// deterministic — a pure function of actor position/rotation and
	// ServePhase — so carrying and releasing the ball from it removes the
	// dependency on the AnimGraph's behavior entirely, rather than chasing
	// which of its parts breaks it this time.
	FVector ServeTossTarget;

	// Distance (cm) at which any player auto-reaches toward the ball. Kept tight so
	// players don't flail at a ball that's still metres away — the AI drives the
	// deliberate reach as it closes in; this is just a safety net at true arm range.
	float AutoReachDistance = 115.0f;

	// Reach for the ball automatically when it's near and I may legally play it.
	// Hit type is picked from the ball's height relative to my body.
	private void AutoReachForBall()
	{
		if (!CanContactBall()) return;
		// An active deliberate reach (AI/dive) owns the pose. AutoReach re-picking
		// the hit type from geometry at frame rate fought the AI's 9Hz choice —
		// alternating IK branches every frame read as violent hand flicker. This
		// is only the safety net for UNDESIGNATED players; it takes over 0.25s
		// after the AI stops asking (which also covers the post-whiff rescue).
		if (bReaching) return;
		ABall B = GetWorldBall();
		if (B == nullptr || !B.bInPlay) return;

		float Dist = (GetActorLocation() - B.Position).Size();
		if (Dist > AutoReachDistance) return;

		// Only if the ball is actually COMING at me (approaching, or dropping
		// right on top of me). A ball merely passing nearby made every bystander
		// throw their arms up, which read as random flailing.
		FVector ToMe = GetActorLocation() - B.Position;
		bool bComing = B.BallVel.DotProduct(ToMe) > 0.0f
			|| (B.BallVel.Z < 0.0f
				&& (GetActorLocation() - FVector(B.Position.X, B.Position.Y, 0)).Size2D() < 80.0f);
		if (!bComing) return;

		// Same rule as the AI: a fingerpass (set) is only legal if we're actually
		// UNDER the ball with the forehead — close horizontally AND ball at/above
		// forehead height. Airborne over a high ball = spike. Otherwise bagger.
		float ForeheadZ = GetActorLocation().Z + PlayerHeight * 0.9f;
		float HorizToBall = (GetActorLocation() - FVector(B.Position.X, B.Position.Y, 0)).Size2D();
		bool bUnderBall = HorizToBall < 70.0f;
		bool bHighEnough = B.Position.Z > ForeheadZ;

		EHitType Type;
		if (!bIsGrounded && bHighEnough)
			Type = EHitType::Hit_Spike;          // jumping at a high ball
		else if (bUnderBall && bHighEnough)
			Type = EHitType::Hit_Set;            // under it in time -> fingerpass
		else
			Type = EHitType::Hit_Bump;           // late/low -> bagger

		// The safety net has no plan, so it asks the SHARED predictor once, here,
		// for the height its own hit-type choice implies — not a private copy.
		FVector Contact = B.Position;
		float Tau = 0.0f;
		float WantZ = (Type == EHitType::Hit_Set) ? ForeheadZ : (FloorZ + 112.0f);
		Predict::BallTimeToHeight(B, WantZ, Contact, Tau);
		Reach(Type, Contact, Tau);
	}


	// --- Physical ball contact ---------------------------------------------
	// The ball calls these. The player no longer teleports the ball's velocity;
	// instead the ball bounces off the player's arm region, and we trigger the
	// matching animation + register the touch.

	// Ball only bounces off hands and forearms. Each is a small sphere centered
	// on the bone, in world space. Radius is how thick the limb is for contact.
	// Forearm/hand contact thickness. A real forearm-platform / cupped hands sweep
	// a fatter volume than a single bone point, so this is generous on purpose:
	// effective catch radius = ArmContactRadius + BallRadius (~42cm), which fairly
	// represents an outstretched arm meeting the ball.
	// STILL 32, and now that is a measured floor rather than an untested habit.
	// With the limb modelled as a real segment the obvious next move was to
	// shrink this toward an actual forearm, which is also what would force the
	// arm poses to be right instead of letting a bubble cover for them. 20 was
	// measured: jump attacks fell 51 -> 15 of ~70 third touches and the attack
	// contact height dropped 84 -> 46cm above the actor centre. The IK cannot
	// yet put the hand on the ball accurately enough to live inside a 31cm
	// volume at swing speed. Tighten this only together with that.
	//
	// RETESTED at 24 after the strike height was fixed to the reach the rig
	// actually has — the change that took third touches hit as an attack from
	// 47% to 69%, i.e. the hand is now meeting the ball far better than when 20
	// was tried. It still does not survive: attacks 15-19 -> 11-14 over three
	// runs each (ranges do not overlap), the attack share back down to 52%, and
	// total contacts 342 -> 311. The hand's residual error at contact is 33cm on
	// a landed spike, so a 35cm effective volume is not a margin, it is the
	// whole budget. Next attempt should wait for that number to come down.
	float ArmContactRadius = 32.0f;

	// Closest point on the segment AB to P. The one piece of maths a limb needs:
	// an arm is a segment between two joints, not a point at one of them.
	private FVector ClosestOnSegment(FVector A, FVector B, FVector P) const
	{
		FVector AB = B - A;
		float L2 = AB.SizeSquared();
		if (L2 < 1.0f) return A;
		float T = Math::Clamp((P - A).DotProduct(AB) / L2, 0.0f, 1.0f);
		return A + AB * T;
	}

	// Test the ball against the arms as CAPSULES — a segment from elbow to wrist
	// per forearm, plus the hand — and fill OutCenter with the closest point on
	// the limb rather than with a joint's position.
	//
	// WHY NOT UE'S OWN. USkeletalMeshComponent::GetClosestPointOnPhysicsAsset is
	// bound in this fork (the K2_ prefix is stripped) and is exactly the right
	// shape of answer: it walks the physics asset's bodies against the ANIMATED
	// pose — GetComponentSpaceTransforms, not simulated bodies — and hands back a
	// closest point, a normal and the bone that owns it. It was tried and it
	// answers `false` every single time: 240 of 240 probes, bone=None. The reason
	// is one line of its implementation, `GetPhysicsAsset()` — the component has
	// no override (deliberately: see SetupRagdollPhysics, applying one destroyed
	// jumps and contacts) and SKM_Manny_Simple carries no default asset of its
	// own, so there is nothing for it to walk. The engine has the feature; this
	// mesh has no geometry to give it.
	//
	// What was actually wrong here was never the lack of an engine call. It was
	// the SHAPE: a forearm modelled as a single sphere at the elbow joint, with a
	// radius (32 + ball) of 42cm to cover for it. That bubble is bigger than the
	// arm is long, so the ball could be played from a pose nowhere near it, and
	// the contact point handed to OnBallContact — which uses it for the bounce
	// normal — was a joint rather than the surface the ball actually met.
	bool GetArmContact(FVector BallPos, float BallRadius, FVector& OutCenter) const
	{
		if (Mesh == nullptr) return false;

		float Reach = ArmContactRadius + BallRadius;
		float ReachSq = Reach * Reach;

		// Forearms: elbow -> wrist. This is the bagger platform, and it is the
		// segment the ball is supposed to come off.
		FVector P = ClosestOnSegment(Mesh.GetBoneTransform(n"lowerarm_r").Location,
			Mesh.GetBoneTransform(n"hand_r").Location, BallPos);
		if ((BallPos - P).SizeSquared() <= ReachSq) { OutCenter = P; return true; }

		P = ClosestOnSegment(Mesh.GetBoneTransform(n"lowerarm_l").Location,
			Mesh.GetBoneTransform(n"hand_l").Location, BallPos);
		if ((BallPos - P).SizeSquared() <= ReachSq) { OutCenter = P; return true; }

		// Hands: wrist -> middle knuckle, the cup that takes a set and the
		// surface that tops a spike.
		P = ClosestOnSegment(Mesh.GetBoneTransform(n"hand_r").Location,
			Mesh.GetBoneTransform(n"middle_01_r").Location, BallPos);
		if ((BallPos - P).SizeSquared() <= ReachSq) { OutCenter = P; return true; }

		P = ClosestOnSegment(Mesh.GetBoneTransform(n"hand_l").Location,
			Mesh.GetBoneTransform(n"middle_01_l").Location, BallPos);
		if ((BallPos - P).SizeSquared() <= ReachSq) { OutCenter = P; return true; }

		return false;
	}

	// Where this player wants to send the ball (set by AI each frame). The ball
	// uses this as the bounce direction on contact.
	FVector DesiredAim = FVector::ZeroVector;
	bool bHasAim = false;

	// PLAN vs ACTUAL: the AI hitter records the budget's promise (slack, speed)
	// and how long it has stood planted; the contact grades them (PLANVA line).
	float PlanSlackLog = -1.0f;
	float PlanSpeedFracLog = -1.0f;
	float PlantedFor = 0.0f;

	// Whether this player is allowed to touch the ball right now. Overridden by
	// AI so a player who made the team's last touch is "transparent" until a
	// different player (teammate or opponent) touches it — no double contacts.
	// A body sliding out a dive has no arms to play with: the limbs are
	// physics-driven, so a contact here would be the simulation flailing into
	// the ball, not a player touching it — and it would still count as one of
	// the team's three.
	bool CanContactBall() const { return !bRagdollActive; }

	// Solve the launch velocity that carries the ball from P to T on a parabola
	// peaking Apex cm above the higher endpoint. This is what a controlled
	// volleyball contact IS: pros don't reflect the ball, they place it — the
	// dig pops to the setter zone, the set floats to the attack spot, both with
	// deliberate arc. (Air drag ~2%/s shortens it slightly; acceptable.)
	FVector BallisticVelocity(FVector P, FVector T, float Apex) const
	{
		const float G = 980.0f;
		float PeakZ = Math::Max(P.Z, T.Z) + Math::Max(Apex, 40.0f);
		float Vz = Math::Sqrt(2.0f * G * (PeakZ - P.Z));
		float TUp = Vz / G;
		float TDown = Math::Sqrt(2.0f * Math::Max(PeakZ - T.Z, 1.0f) / G);
		float TTotal = Math::Max(TUp + TDown, 0.15f);
		return FVector((T.X - P.X) / TTotal, (T.Y - P.Y) / TTotal, Vz);
	}

	// --- Net-plane flight tests (net at X=0). Used to GUARANTEE the three-touch
	// protocol physically: touches 1-2 must stay on our side, touch 3 must clear
	// the tape. Ballistic, drag ignored (2%/s — the margins absorb it).
	private bool CrossesNetPlane(FVector P, FVector V) const
	{
		if (Math::Abs(V.X) < 1.0f) return false;
		float TCross = -P.X / V.X;
		if (TCross <= 0.0f) return false;
		float ZAtCross = P.Z + V.Z * TCross - 490.0f * TCross * TCross;
		return ZAtCross > 0.0f;   // still airborne when it reaches the plane
	}

	private float HeightAtNetPlane(FVector P, FVector V) const
	{
		float TCross = -P.X / V.X;
		return P.Z + V.Z * TCross - 490.0f * TCross * TCross;
	}

	// Minimum height the flight must have over the net plane: tape + ball + margin.
	private float NetClearZ()
	{
		ABall B = GetWorldBall();
		float Tape = (B != nullptr) ? B.NetTopZ + B.BallRadius : 254.0f;
		return Tape + 28.0f;
	}

	// Any opponent parked in the block lane at the net where this flight crosses?
	// A shot that clears the tape by centimetres lands exactly in the standing
	// blocker's catch envelope (hands ~240 + 42cm radius ≈ the 282 tape margin)
	// — a real hitter sees the block and shoots OVER it.
	private bool BlockerInLane(float YAtNet)
	{
		TArray<AActor> Players;
		GetAllActorsOfClass(AVolleyballPlayer, Players);
		for (AActor A : Players)
		{
			AVolleyballPlayer P = Cast<AVolleyballPlayer>(A);
			if (P == nullptr || P.TeamSide == TeamSide) continue;
			FVector L = P.GetActorLocation();
			if (Math::Abs(L.X) < 200.0f && Math::Abs(L.Y - YAtNet) < 160.0f)
				return true;
		}
		return false;
	}

	// A placed attack over the net: ballistic to T, arc raised until it clears
	// the tape — and the BLOCK, when someone is standing in the crossing lane.
	// Raising the apex raises the whole interior of the parabola, so the loop is
	// monotone and terminates. Starts flat/fast (a driven shot) and only lofts
	// as much as the contact height / block force it to.
	FVector AttackBallistic(FVector P, FVector T)
	{
		float Apex = 90.0f;
		FVector V = BallisticVelocity(P, T, Apex);
		int Guard = 0;
		while (Guard < 10 && CrossesNetPlane(P, V))
		{
			float TCross = -P.X / V.X;
			float ZC = P.Z + V.Z * TCross - 490.0f * TCross * TCross;
			float YC = P.Y + V.Y * TCross;
			float Need = NetClearZ() + (BlockerInLane(YC) ? 75.0f : 0.0f);
			if (ZC >= Need) break;
			Apex += 70.0f;
			V = BallisticVelocity(P, T, Apex);
			Guard++;
		}
		return V;
	}

	// Called by the ball when it physically touches this player. The ball gives
	// its current velocity; we return the post-contact velocity.
	//
	// THE THREE-TOUCH PROTOCOL LIVES HERE, not in raw contact geometry: the
	// reception (team touch 1) is ALWAYS a bagger (overhand serve receive is a
	// fault in beach anyway), the second touch is a bagger or a hand set, and
	// the third touch attacks over the net — jump spike if we're airborne at a
	// high ball, otherwise a placed shot. Every controlled contact is ballistic
	// placement now; the old "aimless flail" reflection branch was a rally
	// killer (random direction at 600cm/s) and is gone.
	FVector OnBallContact(FVector BallPos, FVector BallVelIn, FVector Center)
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		int MyTouches = (GS != nullptr && GS.LastTouchTeam == TeamSide) ? GS.TouchesThisRally : 0;

		// A fingerpass is taken at the FOREHEAD, not above the crown. The setter
		// aims to contact at PlayerHeight*0.9 (ContactHeightFor(Hit_Set)); keying
		// the set/bump split off the OLD full-head threshold (PlayerHeight*1.0)
		// meant a perfectly-placed overhead ball at 171cm classified as a BUMP
		// because it sat below the 180cm crown — so nobody ever fingerpassed.
		// Use a forehead threshold a hair below the setter's own target so the
		// intended contact reliably reads as a set. (Kept below the target, not
		// at it, for prediction slack.)
		float SetMinContactZ = GetActorLocation().Z + PlayerHeight * 0.82f;
		bool bHigh = BallPos.Z > SetMinContactZ;
		// An active block gesture at the net keeps its identity — the protocol
		// would otherwise re-type a stuff block as a "reception" and float a
		// point-blank spike gently to the setter zone.
		bool bBlockContact = (CurrentHit == EHitType::Hit_Block && !bIsGrounded);

		EHitType Type;
		if (bBlockContact)
			Type = EHitType::Hit_Block;
		else if (MyTouches == 0)
			Type = EHitType::Hit_Bump;                                   // reception: always bagger
		else if (MyTouches == 1)
			// ATTACK ON TWO is legal: a perfect reception hangs through the
			// strike zone and the second toucher may choose to jump on it —
			// an airborne high contact here IS that choice, made physical.
			Type = (!bIsGrounded && bHigh) ? EHitType::Hit_Spike
			     : ((bHigh && bIsGrounded) ? EHitType::Hit_Set : EHitType::Hit_Bump);
		else
			Type = (!bIsGrounded && bHigh) ? EHitType::Hit_Spike
			     : (bHigh ? EHitType::Hit_Set : EHitType::Hit_Bump);     // grounded attack = shot
		bool bAttackTouch = !bBlockContact
			&& (MyTouches >= 2 || Type == EHitType::Hit_Spike);

		// Where we're sending it. The AI aims continuously; if no aim is active
		// (scramble), fall back to the protocol's natural target: pop receptions
		// to the setter zone, second balls to the attack spot, third balls deep
		// into the opponent court.
		float Own = (TeamSide == ETeam::Team_A) ? -1.0f : 1.0f;
		FVector Target;
		if (bHasAim)
			Target = DesiredAim;
		else if (bBlockContact)
			Target = FVector(-Own * 300.0f, 0.0f, FloorZ);
		else if (MyTouches == 0 || MyTouches == 1)
			// Placement rule: every pass arcs down to the far pin (floor target
			// so an unattacked pass stays IN — see FarPinTarget).
			Target = FVector(Own * 50.0f, (BallPos.Y > 0.0f) ? -350.0f : 350.0f, 20.0f);
		else
			Target = FVector(-Own * 500.0f, (BallPos.Y > 0.0f) ? -180.0f : 180.0f, 15.0f);

		// CONTACT QUALITY (first principles): control degrades with everything
		// the body still has going on at contact — residual locomotion (a
		// moving platform aims worse; quadratic, so a settling drift barely
		// matters while a sprint scatters badly) and unconverged hands (strike
		// hand vs its IK target). This is what makes the planner's "arrive
		// planted and early" measurably worth paying for.
		float BodySpd = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0).Size();
		// AGAINST A REACHABLE GOAL, NOT THE RAW TARGET. The spike deliberately
		// asks for a point past the end of the arm (see the Strike pose: the FBIK
		// saturates at full extension, and under-asking left the hand 40cm below
		// the ball at the apex). Measured against the raw target, that over-ask
		// IS the error: 33cm at the median on a LANDED attack, i.e. on the swings
		// that worked. It was being read as unconverged hands and charged to the
		// aim below, 16cm of scatter on every spike for a target nobody intended
		// the arm to reach. The honest question is whether the arm went as far as
		// it could along the line it was given, so the goal is clamped to the
		// chain's own length first (bone lengths are pose-invariant, so this is
		// the rig's real arm, not a guess).
		float HandErr = 0.0f;
		if (Mesh != nullptr && Anim != nullptr)
		{
			FVector ShoulderP = Mesh.GetBoneTransform(n"upperarm_r").Location;
			FVector ElbowP = Mesh.GetBoneTransform(n"lowerarm_r").Location;
			FVector HandP = Mesh.GetBoneTransform(n"hand_r").Location;
			float ArmLen = (ElbowP - ShoulderP).Size() + (HandP - ElbowP).Size();
			FVector ToT = Anim.HandTargetR - ShoulderP;
			FVector Goal = (ToT.Size() > ArmLen)
				? ShoulderP + ToT.GetSafeNormal() * ArmLen
				: Anim.HandTargetR;
			HandErr = (HandP - Goal).Size();
		}
		float AimErrCm = 0.0f;
		if (!bBlockContact)
		{
			float SpeedFrac = Math::Clamp(BodySpd / MoveSpeed, 0.0f, 1.5f);
			AimErrCm = 140.0f * SpeedFrac * SpeedFrac + 0.5f * Math::Min(HandErr, 120.0f);
			if (AimErrCm > 2.0f)
			{
				float Ang = Math::RandRange(0.0f, 2.0f * PI);
				Target += FVector(Math::Cos(Ang), Math::Sin(Ang), 0)
					* (Math::RandRange(0.35f, 1.0f) * AimErrCm);
			}
		}

		// Physical reflection (arms as a surface) — the flavor component.
		FVector GeoNormal = (BallPos - Center).GetSafeNormal();
		if (GeoNormal.SizeSquared() < 0.01f) GeoNormal = FVector(0, 0, 1);
		FVector AimDir = (Target - BallPos).GetSafeNormal();
		FVector Normal = (GeoNormal * 0.35f + AimDir * 0.65f).GetSafeNormal();
		float VDotN = BallVelIn.DotProduct(Normal);
		FVector Reflected = (BallVelIn - Normal * (2.0f * VDotN)) * 0.35f;

		FVector OutVel;
		if (bBlockContact)
		{
			// A block is a wall, not a placement: real reflection plus a firm
			// downward push toward the middle of their court.
			FVector BlockDir = AimDir;
			BlockDir.Z = Math::Min(BlockDir.Z, -0.15f);
			OutVel = Reflected + BlockDir.GetSafeNormal() * 420.0f;
		}
		else if (bAttackTouch)
		{
			if (Type == EHitType::Hit_Spike)
			{
				// True strike: reflection + hard swing. But never into the tape —
				// if this contact physically can't power over, convert to a driven
				// shot (that's what a hitter does with a low/tight ball).
				FVector SwingDir = AimDir;
				SwingDir.Z = Math::Min(SwingDir.Z, -0.2f);
				OutVel = Reflected + SwingDir.GetSafeNormal() * 1050.0f;
				if (!CrossesNetPlane(BallPos, OutVel) || HeightAtNetPlane(BallPos, OutVel) < NetClearZ())
					OutVel = AttackBallistic(BallPos, Target);
			}
			else
			{
				// Shot: pure placed arc, guaranteed over.
				OutVel = AttackBallistic(BallPos, Target);
			}
		}
		else
		{
			// Touch 1-2: placed arc to our own side. The dash of reflection keeps
			// hot serves feeling physical — but if it would carry the ball over
			// the net (protocol break: only touch 3 crosses), drop it and keep
			// the pure ballistic, which by construction stays on our side.
			// Arc by TOUCH NUMBER and QUALITY. The SECOND ball is the pass the
			// attacker jumps on — with the floor target at the pin its arc must
			// peak ~490 to hang through the 350 strike zone (apex counts above
			// the higher endpoint, so grounding the target lowered every peak
			// by ~3m and the jump attack vanished). The RECEPTION's height is
			// EARNED by contact quality: a planted, converged dig floats the
			// same attackable arc (and the partner may then spike on 2 or
			// hand-set), while a scrambled one only manages the flat
			// defensive pop. Quality gating the arc means "perfect reception
			// = options" falls out of the physics instead of a rule.
			float Apex = (MyTouches == 1)
				? 340.0f
				: Math::Lerp(340.0f, 260.0f, Math::Clamp(AimErrCm / 50.0f, 0.0f, 1.0f));
			FVector Pure = BallisticVelocity(BallPos, Target, Apex);
			OutVel = Pure + Reflected * 0.15f;
			if (CrossesNetPlane(BallPos, OutVel))
				OutVel = Pure;
		}

		// THE SECOND BALL'S ARC, measured at the moment it leaves the setter —
		// this is the whole budget the attacker gets. The jump needs the ball to
		// still be above SpikeStrikeZ (~330) with a load + time-to-apex (~0.76s)
		// left, so both the peak and the time to the descending crossing are
		// decided right here, by this one velocity.
		if (MyTouches == 1 && !bBlockContact)
		{
			float PeakZ = BallPos.Z + (OutVel.Z * OutVel.Z) / (2.0f * 980.0f);
			Log("SETARC contactZ=" + int(BallPos.Z) + " vz=" + int(OutVel.Z)
				+ " peak=" + int(PeakZ) + " type=" + int(Type)
				+ " aimErr=" + int(AimErrCm));
		}

		// PLAN vs ACTUAL: grade the budget's promise at the moment of truth.
		// slack/speedFrac are what the plan booked (×100), settle is how long
		// the body was planted before this contact, bodySpd/handErr/aimErr are
		// what the contact actually paid.
		// RULE 1 (Erik): the ball must be IN FRONT of the chest at contact. Measured
		// in the body's own frame — fwd is along the facing, side is +right — so a
		// negative fwd is literally "armen bakom sig" and is a failed contact even
		// when the distance looks fine.
		FVector ToBall = FVector(BallPos.X - GetActorLocation().X,
			BallPos.Y - GetActorLocation().Y, 0);
		float BallFwd = ToBall.DotProduct(GetActorForwardVector().GetSafeNormal());
		float BallSide = ToBall.DotProduct(GetActorRightVector().GetSafeNormal());
		float BallUp = BallPos.Z - GetActorLocation().Z;
		// ...and where the gesture was AIMED, same frame, so a low contact can be
		// told apart from a low intention: reachUp far above ballUp means the
		// hands were asked high and the ball fell past them, reachUp near ballUp
		// means the plan itself was low (the budget fell back to the waist
		// contact) and the arms did what they were told.
		float ReachUp = bHasReachContact ? (ReachContact.Z - GetActorLocation().Z) : -999.0f;

		Log("PLANVA touch=" + MyTouches + " type=" + int(Type)
			+ " ballFwd=" + int(BallFwd) + " ballSide=" + int(BallSide)
			+ " ballUp=" + int(BallUp)
			+ " reachUp=" + int(ReachUp)
			+ " slack=" + int(PlanSlackLog * 100.0f)
			+ " speedFrac=" + int(PlanSpeedFracLog * 100.0f)
			+ " settle=" + int(PlantedFor * 100.0f)
			+ " bodySpd=" + int(BodySpd)
			+ " handErr=" + int(HandErr)
			+ " aimErr=" + int(AimErrCm)
			+ " grounded=" + bIsGrounded
			// WHO WAS FALLING PAST WHOM. A third touch taken airborne but at waist
			// height is either an EARLY JUMP (the body already coming down, myVz
			// strongly negative, while the ball is still up) or a ball that FELL PAST
			// the hands (ballVz strongly negative, myVz near the top of the arc).
			// The two call for opposite fixes and nothing logged could tell them apart.
			// How high the HAND actually was, same frame and same frame of
			// reference as ballUp: SpikeStrikeZ assumes a reach of
			// StrikeReachAboveCenter above the body centre, and the whole jump
			// timing is built on that assumption being true.
			+ " handUp=" + int(Mesh != nullptr
				? Mesh.GetBoneTransform(n"hand_r").Location.Z - GetActorLocation().Z
				: -999.0f)
			+ " myVz=" + int(PlayerVelocity.Z)
			+ " ballVz=" + int(BallVelIn.Z)
			+ " bookedInfeasible=" + (bBookedInfeasible ? 1 : 0));
		PlanSlackLog = -1.0f;
		PlanSpeedFracLog = -1.0f;

		TriggerHit(Type, OutVel.GetSafeNormal());
		RegisterHit(GetWorldBall());
		bHasAim = false;
		return OutVel;
	}

	// The ball passes itself for touch registration; we keep a cached ref.
	// Public so the IK mixin can locate the ball to aim the hands at it.
	private ABall CachedBall;
	ABall GetWorldBall()
	{
		if (CachedBall == nullptr)
		{
			TArray<AActor> Found;
			GetAllActorsOfClass(ABall, Found);
			if (Found.Num() > 0) CachedBall = Cast<ABall>(Found[0]);
		}
		return CachedBall;
	}

	// Maps gameplay hit type to the Anim BP's three upper-body clip slots.
	//
	// SERVE AND BLOCK MUST NEVER SELECT THE SPIKE SLOT (index 2). This isn't
	// about blend weight — Anim.HitAlpha gating the overlay to 0 for these two
	// types was tried FIRST and measured to do nothing (RALLY end
	// reason=serve_net stayed at 47% of rallies on a live A/B in an isolated
	// worktree, real assets, alpha genuinely zeroed). The corruption comes
	// from SELECTING the branch/clip at all — HitClipBranch=1 with
	// HitSetSpikeBlend=1.0 (routing toward MM_Attack_01, the spike swing)
	// still corrupts things this hit type depends on real bone reads for,
	// however small the outer overlay weight. Only changing the RETURNED
	// INDEX so Serve/Block never reach branch 2 fixed it: the same worktree,
	// same commit, same real assets, serve_net dropped from 47% to 9% (the
	// ~1/130-rally baseline this project already had before any of this).
	//
	// The serve's toss carries the ball from a live
	// Mesh.GetBoneTransform(hand_l) read every frame (RunServeSequence in
	// AIPlayer.as) — the toss's whole flight is the symmetric parabola between
	// TWO samples of that read, so a corrupted read corrupts the entire toss,
	// not just one frame of it. Block reads real bone positions too
	// (GetArmContact tests the arm against the ball every frame) for the same
	// underlying reason it must stay off branch 2.
	private int HitClipIndexFor(EHitType Type) const
	{
		if (Type == EHitType::Hit_Set)
			return 1;
		if (Type == EHitType::Hit_Spike)
			return 2;
		return 0;   // bump, none, serve, block: no fitting clip, or none needed
	}

	// Called by gameplay code each time a contact happens. Sets which upper-body
	// hit montage the Anim Blueprint should blend in.
	protected void TriggerHit(EHitType Type, FVector WorldDir)
	{
		ReachDir = WorldDir.GetSafeNormal();
		CurrentHit = Type;      // a real contact is an event — no dwell gate
		GestureAge = 0.0f;
		HitAnimTimer = HitAnimDuration;
		// Whip telemetry: rolling peak of hand-target speed entering this
		// contact (cm/s). A real spike/serve whip should read 1500-2300; a
		// bump platform a few hundred.
		Log("SWING type=" + int(Type) + " peakHand=" + int(PeakHandSpd));
		if (bDebugHit)
		{
			FString Cls = (Anim != nullptr) ? "" + Anim.GetClass().GetName() : "NULL";
			Log("HIT type=" + int(Type) + " AnimInstance=" + Cls);
		}
	}

	bool bDebugHit = false;

	// Back-compat: a generic reach with no specific hit type.
	protected void TriggerReach(FVector WorldDir)
	{
		TriggerHit(EHitType::Hit_Bump, WorldDir);
	}


	UFUNCTION(BlueprintCallable)
	void MovePlayer(FVector2D Input)
	{
		// Store the desired move; UpdatePlayer eases the real velocity toward it.
		// Players no longer teleport between speeds — explosive first step, hard
		// plant when stopping, and momentum carries through jumps (with only weak
		// steering in the air, so no mid-jump swimming).
		MoveInput = Input;
	}

	// Desired input this frame (unit length or less). Consumed by UpdatePlayer.
	private FVector2D MoveInput = FVector2D::ZeroVector;

	// Mirrors the travel-wins choice in UpdatePlayer (telemetry / DbgFacingSrc).
	private bool bTurnRun = false;

	// Horizontal acceleration rates (cm/s²). Ground values give a sprinter-like
	// first step (0→full in ~0.2s) and a decisive plant (full→0 in ~0.13s, sliding
	// ~30cm — matches the AI's 40cm plant radius). Air rate is weak on purpose.
	// ANISOTROPIC LOCOMOTION (first principles): legs drive hardest along the
	// facing — backpedaling keeps the eyes on the ball at ~62% of forward
	// speed, shuffling sideways ~81%. The MotionPlan planner reads the same
	// scale, so its time budgets and the sim can never disagree about how
	// fast a facing-locked hitter really closes.
	const float BackpedalScale = 0.62f;
	float MoveDirSpeedScale(FVector Dir) const
	{
		FVector F = GetActorForwardVector();
		FVector D = FVector(Dir.X, Dir.Y, 0.0f);   // params are const in AS
		F.Z = 0.0f;
		if (F.SizeSquared() < 0.01f || D.SizeSquared() < 0.01f) return 1.0f;
		float Dot = F.GetSafeNormal().DotProduct(D.GetSafeNormal());
		return Math::Lerp(BackpedalScale, 1.0f, (Dot + 1.0f) * 0.5f);
	}

	// ACCELERATION IS A HUMAN LIMIT, NOT A TUNING KNOB.
	//
	// These were 2400/3400 cm/s^2 — 24 and 34 m/s^2, measured straight out of a
	// match by the BIOMECH line. A sprinter's first step peaks near 10 m/s^2 and
	// a hard controlled plant near 12, so the body was accelerating 2.4x and
	// braking 2.8x harder than any human can, reaching top speed in 0.24s. No
	// amount of animation polish reads as real on top of that: the legs are
	// being asked to explain motion the legs could not produce.
	//
	// Safe to lower because MotionPlan budgets travel time from these very
	// values (trapezoid accel/cruise/brake profile), so the AI simply starts
	// moving earlier instead of misjudging what it can reach — as long as the
	// planner reads them rather than duplicating them, which is why MB_Brake
	// was removed in favour of passing GroundDecel through.
	//
	// Kept at the TOP of the human band rather than mid: these are athletes, and
	// the game still has to be playable at volleyball tempo.
	float GroundAccel = 1000.0f;   // 10 m/s^2
	float GroundDecel = 1200.0f;   // 12 m/s^2
	float AirAccel = 350.0f;

	// Ease PlayerVelocity.XY toward the requested input velocity.
	private void ApplyMoveInput(float DeltaTime)
	{
		FVector Cur = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0);
		FVector InDir = FVector(MoveInput.X, MoveInput.Y, 0);
		// Anisotropic: top speed scales with travel-vs-facing (see
		// MoveDirSpeedScale). Applied at the input level so the AI planner and
		// any future gamepad input obey the same body.
		FVector Target = InDir * (MoveSpeed * MoveDirSpeedScale(InDir));

		float Rate;
		if (!bIsGrounded)
			Rate = AirAccel;
		else if (Target.SizeSquared() > Cur.SizeSquared() + 1.0f)
			Rate = GroundAccel;
		else
			Rate = GroundDecel;

		FVector Delta = Target - Cur;
		float MaxStep = Rate * DeltaTime;
		if (Delta.Size() > MaxStep)
			Delta = Delta.GetSafeNormal() * MaxStep;

		PlayerVelocity.X = Cur.X + Delta.X;
		PlayerVelocity.Y = Cur.Y + Delta.Y;
	}

	// --- Dive: explosive low lunge at a ball that can't be reached on foot -----
	// Physics-only (no dive montage dependency): a burst of speed with a small hop,
	// body forced low via ExtraCrouch, arms reaching via the normal bump IK. The
	// recovery phase keeps the player slow and low while "getting up".
	float DiveTimer = 0.0f;
	float DiveRecoverTimer = 0.0f;
	private FVector DiveDir = FVector(1, 0, 0);
	const float DiveDuration = 0.42f;
	const float DiveRecovery = 0.75f;
	// A DIVE IS A LUNGE, NOT A ROCKET. This was 1.75, which at the AI's move
	// speed put the body through the sand at 10.2 m/s — sprint-record territory,
	// in a dive. It survived because the BIOMECH ratchet gates acceleration and
	// never gated SPEED, and because nothing downstream complained: the dig's
	// aim error is quadratic in body speed and simply saturated at its cap on
	// every dive, so a dive was a coin toss that also left the diver metres out
	// of position.
	//
	// Measured, 1.75 -> 1.15 (three runs each, ranges not overlapping):
	//   contacts per rally      4.08-5.14 -> 7.44-8.00
	//   median rally length     3 -> 6 touches (both sides now build)
	//   worst dig aim error     359cm -> 197
	// with attacks unchanged. 1.0 measures the same as 1.15 (6.68-8.06); 1.15 is
	// kept because a lunge IS briefly faster than a run — just not twice as fast.
	//
	const float DiveSpeedMul = 1.15f;
	// Push-off rate for the lunge, cm/s^2. See UpdateDive: this is in the plant
	// band (3-5x bodyweight, the most violent legal thing in the sport), not the
	// sprint band, because that is what a dive take-off is.
	const float DiveAccel = 4000.0f;

	// Ragdoll slide at dive landing: physics blend on PA_Mannequin, capsule follows
	// the pelvis horizontally while the body deforms sand on contact.
	bool bRagdollActive = false;
	float RagdollTimer = 0.0f;
	float RagdollBlend = 0.0f;
	// Set when DiveTimer expires while still airborne — StartRagdollSlide waits
	// for bIsGrounded so a mid-air Death_Front + physics blend can't flip the
	// body butt-over-head.
	bool bPendingRagdollSlide = false;
	// A BACKSTOP, not the length of a slide — UpdateRagdollSlide ends when the
	// body stops. Generous enough that it only ever catches a pathological
	// entry speed.
	const float RagdollDuration = 0.40f;
	const float RagdollBlendIn = 0.10f;
	const float RagdollBlendOut = 0.30f;

	bool IsDiving() const { return DiveTimer > 0.0f || bPendingRagdollSlide; }
	bool CanDive() const
	{
		return bIsGrounded && DiveTimer <= 0.0f && DiveRecoverTimer <= 0.0f
			&& !bRagdollActive && !bPendingRagdollSlide;
	}

	void StartDive(FVector WorldDir)
	{
		FVector Flat = FVector(WorldDir.X, WorldDir.Y, 0);
		if (Flat.SizeSquared() < 0.01f) return;
		DiveDir = Flat.GetSafeNormal();
		DiveTimer = DiveDuration;
		bPendingRagdollSlide = false;
		// Stay ON the sand. A Z-hop while a face-plant clip played put the body
		// in the air butt-first / upside-down. Dive = grounded lunge.
		PlayerVelocity.Z = 0.0f;
		bIsGrounded = true;
		ExtraCrouch = Math::Max(ExtraCrouch, 0.35f);
	}

	private void UpdateDive(float DeltaTime)
	{
		if (DiveTimer > 0.0f)
		{
			DiveTimer -= DeltaTime;
			// The dive owns the velocity and the facing while active — but it
			// ACCELERATES INTO IT rather than assigning it. Assignment is an
			// infinite first frame, and it was not a theoretical complaint: every
			// one of the 265 acceleration excursions logged in a three-run match
			// carried dive=1, and the peak read 286 m/s^2 against a human limit
			// of 10. The dive was the only thing in the game breaking that band,
			// and it broke it by two orders of magnitude.
			//
			// DiveAccel sits in the PLANT band, not the sprint band, because a
			// dive push-off is the same class of event as a spike gather: brief,
			// explosive, and legal at 3-5x bodyweight. It reaches the lunge speed
			// in ~0.17s, comfortably inside the 0.42s dive.
			FVector DiveWant = DiveDir * (MoveSpeed * DiveSpeedMul);
			FVector DiveCur = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0.0f);
			FVector DiveStep = DiveWant - DiveCur;
			float DiveMax = DiveAccel * DeltaTime;
			if (DiveStep.Size() > DiveMax)
				DiveStep = DiveStep.GetSafeNormal() * DiveMax;
			PlayerVelocity.X = DiveCur.X + DiveStep.X;
			PlayerVelocity.Y = DiveCur.Y + DiveStep.Y;
			FacingDir = DiveDir;
			bHasFacing = true;
			ExtraCrouch = Math::Max(ExtraCrouch, 0.35f);
			if (DiveTimer <= 0.0f)
			{
				DiveRecoverTimer = DiveRecovery;
				// No ragdoll: PA_Mannequin blend buried limbs under the sand and
				// tumbled the mesh. Recovery crouch is enough to sell the landing.
				bPendingRagdollSlide = false;
			}
		}
		else if (bPendingRagdollSlide)
		{
			// Legacy path — ragdoll slide is disabled; clear any stale flag.
			bPendingRagdollSlide = false;
			DiveRecoverTimer = Math::Max(DiveRecoverTimer, DiveRecovery * 0.5f);
		}
		else if (bRagdollActive)
		{
			// If a previous build left a slide running, tear it down immediately.
			EndRagdollSlide();
			if (DiveRecoverTimer > 0.0f)
				DiveRecoverTimer -= DeltaTime;
		}
		else if (DiveRecoverTimer > 0.0f)
		{
			DiveRecoverTimer -= DeltaTime;
			// Getting up: mild kneel, not a full sink — 0.85 buried the knees
			// under the sand when combined with pelvis Modify Bone.
			ExtraCrouch = Math::Max(ExtraCrouch, 0.35f * (DiveRecoverTimer / DiveRecovery));
		}
	}

	private void StartRagdollSlide()
	{
		if (!bRagdollReady || Mesh == nullptr) return;

		bRagdollActive = true;
		RagdollTimer = RagdollDuration;
		RagdollBlend = 0.0f;

		// Borrow the physics asset for the slide (see SetupRagdollPhysics).
		Mesh.SetPhysicsAsset(RagdollPhysAsset, true);
		Mesh.SetEnablePhysicsBlending(true);
		Mesh.SetCollisionProfileName(n"Ragdoll");
		Mesh.SetCollisionEnabled(ECollisionEnabled::QueryAndPhysics);

		FVector SlideVel = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0);
		Mesh.SetAllBodiesBelowLinearVelocity(n"pelvis", SlideVel, true);
	}

	private void UpdateRagdollSlide(float DeltaTime)
	{
		RagdollTimer -= DeltaTime;

		// End FIRST, and brake nothing on the frame we end. UpdateDive runs
		// before ApplyMoveInput, so a slide that both decelerated and cleared
		// bRagdollActive in the same frame got braked twice — once here and once
		// by ApplyMoveInput a few lines later. That read as 24 m/s^2 against a
		// 12 limit, and it was purely the seam, not the slide.
		if (RagdollTimer <= 0.0f)
		{
			EndRagdollSlide();
			return;
		}

		// THE CAPSULE OWNS ITS OWN POSITION.
		//
		// This used to read the simulated pelvis and SetActorLocation to it every
		// frame, which imported the ragdoll's frame-to-frame wobble straight into
		// the one thing the entire game treats as "where the player is". Measured
		// cost, isolated by reverting this feature alone: decel 62 m/s^2 against a
		// 12 limit, wasted travel 240 against 60, and no player jumped at all
		// across 145 rallies.
		//
		// Physics now drives only the LOOK. The slide is a plain deceleration at
		// GroundDecel — the same constant every other stop in this game uses — so
		// it is human-plausible by construction rather than by luck, and it
		// travels through the normal floor and court clamps like all other motion.
		FVector Flat = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0.0f);
		float Speed = Flat.Size();
		float NewSpeed = Math::Max(0.0f, Speed - GroundDecel * DeltaTime);
		if (Speed > 0.01f)
		{
			FVector Dir = Flat / Speed;
			PlayerVelocity.X = Dir.X * NewSpeed;
			PlayerVelocity.Y = Dir.Y * NewSpeed;
		}

		// Blend the physics out over the last stretch of the slide, measured by
		// how long there is left to travel rather than by a fixed duration — a
		// hard dive slides long, a soft one settles quickly, instead of every
		// dive taking exactly RagdollDuration regardless of how fast it was.
		float StopIn = NewSpeed / Math::Max(GroundDecel, 1.0f);
		if (StopIn < RagdollBlendOut)
			RagdollBlend = Math::Max(0.0f, StopIn / RagdollBlendOut);
		else
			RagdollBlend = Math::Min(1.0f, RagdollBlend + DeltaTime / RagdollBlendIn);

		Mesh.SetPhysicsBlendWeight(RagdollBlend);
		// No ExtraCrouch here: a full crouch during the flat Death_Front slide
		// buried knees/feet under the sand and fought the dive clip. Getting-up
		// crouch lives in the DiveRecoverTimer branch after the slide ends.

		// Sand craters under torso and reaching hands — the payoff for
		// PA_Mannequin, and the one place the simulated bones SHOULD be read:
		// where the body touches the sand is a visual question, not a gameplay
		// one, so a few centimetres of physics wobble costs nothing here.
		if (Court != nullptr && RagdollBlend > 0.2f)
		{
			FVector Pelvis = Mesh.GetBoneTransform(n"pelvis").Location;
			float D = 5.0f + 4.0f * RagdollBlend;
			Court.DeformSand(FVector(Pelvis.X, Pelvis.Y, 0), 30.0f, D);
			FVector HandL = Mesh.GetBoneTransform(n"hand_l").Location;
			FVector HandR = Mesh.GetBoneTransform(n"hand_r").Location;
			Court.DeformSand(FVector(HandL.X, HandL.Y, 0), 18.0f, D * 0.7f);
			Court.DeformSand(FVector(HandR.X, HandR.Y, 0), 18.0f, D * 0.7f);
		}

		// Over early if the body actually stopped before the window ran out.
		if (NewSpeed <= 5.0f)
			EndRagdollSlide();
	}

	private void EndRagdollSlide()
	{
		bRagdollActive = false;
		RagdollBlend = 0.0f;
		if (Mesh != nullptr)
		{
			Mesh.SetPhysicsBlendWeight(0.0f);
			Mesh.SetEnablePhysicsBlending(false);
			Mesh.SetCollisionEnabled(ECollisionEnabled::NoCollision);
			// Hand the bones back to the animation — GetBoneTransform has to mean
			// "where the animation put it" again the moment the slide is over.
			Mesh.SetPhysicsAsset(nullptr, true);
		}
	}

	UFUNCTION(BlueprintCallable)
	void Jump()
	{
		if (bIsGrounded)
		{
			PlayerVelocity.Z = JumpVelocity;
			bIsGrounded = false;
		}
	}

	// --- Loaded jump: the full-body gather every real attack/block jump has —
	// plant, sink deep (the arms are already back in the swing windup), then
	// explode. The load converts the gather into HEIGHT: ~115cm rise vs the
	// reactive jump's ~70cm (at the heavy player gravity above).
	float JumpLoadTimer = 0.0f;
	const float JumpLoadDuration = 0.16f;
	// 585 gives a 90cm ballistic rise at this gravity — the TOP of the elite
	// range (60-90), which is where these players belong. It was 660, i.e. a
	// 115cm jump no human has made; SpikeStrikeZ compensated with short arms.
	// See StrikeReachAboveCenter: the reach grew by exactly what the jump lost,
	// so the contact height and every budget derived from it are unchanged.
	const float LoadedJumpVelocity = 585.0f;
	// Fraction of the approach speed that survives the gather (the residue that
	// drifts the body into the contact). Was applied as an instant multiply.
	const float JumpLoadSpeedKeep = 0.25f;
	private FVector JumpLoadEntryVel = FVector::ZeroVector;

	bool IsJumpLoading() const { return JumpLoadTimer > 0.0f; }

	void StartLoadedJump()
	{
		if (!bIsGrounded || JumpLoadTimer > 0.0f) return;
		// The plant: the gather brakes the run — momentum becomes height, and
		// the small residue drifts the body into the contact during the ascent.
		//
		// Braked ACROSS the load, not in the frame it starts. This used to be a
		// flat `*= 0.25` here, which is a velocity teleport: 584 -> 139 cm/s in a
		// single 5ms frame, measured as 757 m/s^2 and by far the largest physical
		// violation in the game. A real approach plant is violent but finite —
		// the foot is on the ground for the whole gather. Spreading the same
		// 75% loss over JumpLoadDuration keeps the intent and the resulting jump
		// height while making the deceleration something legs could produce.
		JumpLoadEntryVel = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0.0f);
		JumpLoadTimer = JumpLoadDuration;
	}

	private void UpdateJumpLoad(float DeltaTime)
	{
		if (JumpLoadTimer <= 0.0f) return;
		if (!bIsGrounded) { JumpLoadTimer = 0.0f; return; }   // knocked airborne: cancel

		// Sink through the load — deepest right before the explosion.
		float Prog = 1.0f - JumpLoadTimer / JumpLoadDuration;
		ExtraCrouch = Math::Max(ExtraCrouch, 0.65f * Prog);

		// Bleed the run off over the gather (see StartLoadedJump). Written as an
		// absolute position along the ramp rather than a per-frame multiply so
		// the total loss is exactly 75% regardless of frame rate — a per-frame
		// scale would brake harder at 250fps than at 30.
		FVector Braked = JumpLoadEntryVel * Math::Lerp(1.0f, JumpLoadSpeedKeep, Prog);
		PlayerVelocity.X = Braked.X;
		PlayerVelocity.Y = Braked.Y;

		JumpLoadTimer -= DeltaTime;
		if (JumpLoadTimer <= 0.0f)
		{
			PlayerVelocity.Z = LoadedJumpVelocity;
			bIsGrounded = false;
		}
	}

	UFUNCTION(BlueprintCallable)
	void TryPass(ABall Ball)
	{
		if (Ball == nullptr || !bCanHit || !IsNearBall(Ball)) return;
		float XDir = (TeamSide == ETeam::Team_A) ? 1.0f : -1.0f;
		FVector Dir = FVector(XDir * 0.4f, 0, 1.0f).GetSafeNormal();
		Ball.HitBall(Dir, 520.0f);
		TriggerHit(EHitType::Hit_Bump, FVector(0, 0, 1));
		RegisterHit(Ball);
	}

	UFUNCTION(BlueprintCallable)
	void TrySet(ABall Ball)
	{
		if (Ball == nullptr || !bCanHit || !IsNearBall(Ball)) return;
		float XDir = (TeamSide == ETeam::Team_A) ? 1.0f : -1.0f;
		FVector Dir = FVector(XDir * 0.65f, 0, 0.76f).GetSafeNormal();
		Ball.HitBall(Dir, 620.0f);
		TriggerHit(EHitType::Hit_Set, FVector(XDir * 0.5f, 0, 1.0f));
		RegisterHit(Ball);
	}

	UFUNCTION(BlueprintCallable)
	void TrySpike(ABall Ball)
	{
		if (Ball == nullptr || !bCanHit || !IsNearBall(Ball)) return;
		float XDir = (TeamSide == ETeam::Team_A) ? 1.0f : -1.0f;
		FVector ToNet = FVector(XDir, 0, -0.35f).GetSafeNormal();
		Ball.HitBall(ToNet, 1300.0f);
		TriggerHit(EHitType::Hit_Spike, FVector(XDir * 0.4f, 0, 1.0f));
		RegisterHit(Ball);
	}

	// Generic hit toward a direction with an explicit hit type (used by AI).
	void HitToward(FVector Dir, float Speed, ABall Ball, EHitType Type = EHitType::Hit_Bump)
	{
		if (Ball == nullptr || !bCanHit) return;
		Ball.HitBall(Dir, Speed);
		TriggerHit(Type, Dir);
		RegisterHit(Ball);
	}

	protected bool IsNearBall(ABall Ball) const
	{
		return (GetActorLocation() - Ball.GetActorLocation()).Size() < 120.0f;
	}

	protected void RegisterHit(ABall Ball)
	{
		bCanHit = false; HitTimer = 0;
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS != nullptr)
		{
			bool bValid = GS.RegisterTouch(TeamSide);
			if (!bValid && GM != nullptr) GM.OnTouchViolation(TeamSide);
			// Rally telemetry: which team, which touch number, which stroke.
			if (bValid && GM != nullptr)
				GM.OnTouchForRally(TeamSide, GS.TouchesThisRally, CurrentHit);
		}
		OnTouchRegistered();
	}

	// Hook for subclasses (AI) to react when this player legally touches the ball.
	protected void OnTouchRegistered() {}

	// Team colour for the fallback cube (SpawnFallbackBox) when the mesh itself
	// fails to load. The real body no longer uses this — see ApplyTeamMaterial —
	// team identity there is TeamRingColor() on the sand ring instead.
	//
	// Deliberately over-1.0 (HDR), the same trick Ball.as uses to make the ball
	// actually read as yellow: BasicShapeMaterial's "Color" multiplies into a lit
	// shade, so sub-1.0 values read as dark under this scene's warm, dim light.
	private FLinearColor TeamColor() const
	{
		return (TeamSide == ETeam::Team_A)
			? FLinearColor(0.30f, 0.70f, 1.90f, 1)
			: FLinearColor(1.90f, 0.35f, 0.30f, 1);
	}

}
