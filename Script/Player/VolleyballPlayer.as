// Base player pawn — movement, jump, physical ball contact, IK targets,
// and skeletal (Manny) body. Drives UVolleyballAnimInstance (see PlayerAnim.as).

class AVolleyballPlayer : APawn
{
	UPROPERTY(DefaultComponent, RootComponent)
	UCapsuleComponent Capsule;

	UPROPERTY(DefaultComponent, Attach = Capsule)
	USkeletalMeshComponent Mesh;

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
			// loader it can fail before its packages have been re-saved in UE 5.7.
			// MoverExamples is enabled for this project and supplies the matching,
			// current-engine Manny mesh as a safe runtime fallback.
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

		// Tint per-team via the body material's vertex/param if available
		ApplyTeamMaterial();
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
		UMaterialInterface BaseMat = Mesh.GetMaterial(0);
		if (BaseMat == nullptr) return;
		UMaterialInstanceDynamic MID = Mesh.CreateDynamicMaterialInstance(0, BaseMat);
		if (MID != nullptr)
			MID.SetVectorParameterValue(n"Tint", TeamColor());
	}

	void UpdatePlayer(float DeltaTime)
	{
		// Dive overrides input; otherwise ease velocity toward the stored input.
		UpdateDive(DeltaTime);
		UpdateJumpLoad(DeltaTime);
		if (!IsDiving())
			ApplyMoveInput(DeltaTime);

		// Gravity
		if (!bIsGrounded)
			PlayerVelocity.Z += Gravity * DeltaTime;

		bool bWasGrounded = bIsGrounded;
		float FallSpeed = -PlayerVelocity.Z;

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
		FVector Feet = FVector(NewLoc.X, NewLoc.Y, 0.0f);
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
		float HSpeed2 = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0).Size();
		if (bHasFacing)
			FacingHoldTimer = 0.2f;
		else
			FacingHoldTimer -= DeltaTime;

		FVector Want = FVector::ZeroVector;
		if (FacingHoldTimer > 0.0f && FacingDir.SizeSquared() > 0.01f)
			Want = FVector(FacingDir.X, FacingDir.Y, 0);
		else if (HSpeed2 > 30.0f)
			Want = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0);

		if (Want.SizeSquared() > 0.01f)
		{
			FRotator Cur = GetActorRotation();
			float Alpha = Math::Clamp(8.0f * DeltaTime, 0.0f, 1.0f);
			SetActorRotation(Math::LerpShortestPath(Cur, Want.Rotation(), Alpha));
		}
		bHasFacing = false;   // requests lapse via FacingHoldTimer above

		UpdatePredictedMeet();
		UpdateAnimation(DeltaTime, HSpeed2);
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

		Anim.Speed         = HSpeed;
		Anim.ForwardSpeed  = FlatVel.DotProduct(Fwd);
		Anim.StrafeSpeed   = FlatVel.DotProduct(Right);
		// HYSTERESIS: a single threshold made bIsMoving flip every frame when
		// the speed hovered at the boundary (deceleration, hold drift), and the
		// Anim BP popped between the idle and locomotion poses at frame rate.
		bMovingState = bMovingState ? (HSpeed > 30.0f) : (HSpeed > 70.0f);
		Anim.bIsMoving     = bMovingState;
		Anim.bIsInAir      = !bIsGrounded;
		Anim.VerticalSpeed = PlayerVelocity.Z;
		Anim.bDiving       = IsDiving();

		Anim.bIsHitting = HitAnimTimer > 0.0f || bReaching;
		Anim.HitType    = CurrentHit;

		// Head tracks the ball: always look at it while it's in play, so every
		// player keeps their eyes on the ball. The Anim BP drives a Look At node on
		// the head bone toward LookTarget with weight LookAlpha.
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

		Anim.HitAlpha = CurrentPose;
		Anim.IKAlpha  = IKWeight;
		// Pose shape uses the full 0..1 gesture curve, remapped so even the 0.85
		// reach hold reaches the contact shape (reach should look committed).
		float Shape = Math::Clamp(CurrentPose / 0.85f, 0.0f, 1.0f);
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
		if (ReachHoldTimer <= 0.0f)
			bReaching = false;
		CrouchHoldTimer -= DeltaTime;
		if (CrouchHoldTimer <= 0.0f)
		{
			// DECAY, don't hard-zero: the AI re-requests every ~0.11s and the
			// hold is 0.25s, but sources that flip per tick (plant crouch at the
			// goal-radius boundary) made ExtraCrouch sawtooth 0 <-> 0.45 — the
			// body visibly bobbed up and down. Standing up is never urgent.
			ExtraCrouch = Math::Max(0.0f, ExtraCrouch - 2.5f * DeltaTime);
		}
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

	// ANTI-FLICKER SINK STATE: everything the ABP sees is speed-limited at the
	// single write point (end of UpdateIKTargets). Public: the mixin owns them.
	FVector SmHandR;
	FVector SmHandL;
	FVector SmPoleR;
	FVector SmPoleL;
	FRotator SmRotR;
	FRotator SmRotL;
	float SmCrouch = 0.0f;
	bool bSmInit = false;

	// Extra crouch (0..1) requested for THIS frame by AI/dive: athletic ready
	// stance, split step dip, dive recovery. Added on top of the pose crouch in
	// UpdateIKTargets, then cleared each frame (same lapse pattern as bReaching).
	float ExtraCrouch = 0.0f;

	// Landing absorption state (knees flex on touchdown, see UpdatePlayer).
	private float LandAbsorbTimer = 0.0f;
	private float LandAbsorbDepth = 0.5f;

	// AI sets this while preparing to play the ball, with the hit type it
	// intends, so the arms extend toward the ball before contact. Requests are
	// held for a beat (not cleared per-frame) because the AI only re-asserts
	// every ReactionDelay — clearing each frame made poses sawtooth between ticks.
	bool bReaching = false;
	private float ReachHoldTimer = 0.0f;
	private float CrouchHoldTimer = 0.0f;

	void Reach(EHitType Type)
	{
		bReaching = true;
		ReachHoldTimer = 0.25f;
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
		}
	}

	// Age of the current gesture type; guards against per-frame branch flips.
	private float GestureAge = 10.0f;
	const float MinGestureDwell = 0.15f;

	// Crouch request that survives between AI reaction ticks (ready stance etc.).
	// Per-frame writers (split step, dive) can set ExtraCrouch directly instead.
	void RequestCrouch(float Amount)
	{
		ExtraCrouch = Math::Max(ExtraCrouch, Amount);
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

	// --- Predicted meet points, cached once per frame -----------------------
	// Where the incoming ball will next descend through bump-platform height
	// (waist, FloorZ+112) and through set height (above the brow). The IK PARKS
	// the platform/cup at these STATIC points instead of chasing the live ball:
	// the ABP's FBIK effectors converge on static targets (booth-verified) but
	// lag behind moving ones — chasing is why fast serves went through the arms.
	FVector PredictedMeetLow;
	bool bHasPredictedMeetLow = false;
	FVector PredictedMeetHigh;
	bool bHasPredictedMeetHigh = false;

	private bool PredictBallCrossZ(ABall B, float TargetZ, FVector& Out) const
	{
		FVector P = B.Position;
		FVector V = B.BallVel;
		if (P.Z <= TargetZ && V.Z <= 0.0f) { Out = P; return true; }   // already at/below, dropping
		const float SimDt = 0.025f;
		float T = 0.0f;
		while (T < 2.5f)
		{
			V.Z += -980.0f * SimDt;
			P += V * SimDt;
			if (P.Z <= TargetZ && V.Z < 0.0f) { Out = P; return true; }
			if (P.Z <= 0.0f) break;
			T += SimDt;
		}
		return false;
	}

	private void UpdatePredictedMeet()
	{
		bHasPredictedMeetLow = false;
		bHasPredictedMeetHigh = false;
		ABall B = GetWorldBall();
		if (B == nullptr || !B.bInPlay) return;
		bHasPredictedMeetLow  = PredictBallCrossZ(B, FloorZ + 112.0f, PredictedMeetLow);
		bHasPredictedMeetHigh = PredictBallCrossZ(B, GetActorLocation().Z + PlayerHeight * 0.9f, PredictedMeetHigh);
	}

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

		Reach(Type);
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
	float ArmContactRadius = 32.0f;

	// Test the ball against the hand/forearm bones. If any is within reach,
	// fills OutCenter with that bone's position and returns true.
	bool GetArmContact(FVector BallPos, float BallRadius, FVector& OutCenter) const
	{
		if (Mesh == nullptr) return false;

		// Bones that can legally play the ball (hands + forearms, both sides).
		FName Bones0 = n"hand_r";
		FName Bones1 = n"hand_l";
		FName Bones2 = n"lowerarm_r";
		FName Bones3 = n"lowerarm_l";

		float Reach = ArmContactRadius + BallRadius;
		float ReachSq = Reach * Reach;

		FVector P;
		P = Mesh.GetBoneTransform(Bones0).Location;
		if ((BallPos - P).SizeSquared() <= ReachSq) { OutCenter = P; return true; }
		P = Mesh.GetBoneTransform(Bones1).Location;
		if ((BallPos - P).SizeSquared() <= ReachSq) { OutCenter = P; return true; }
		P = Mesh.GetBoneTransform(Bones2).Location;
		if ((BallPos - P).SizeSquared() <= ReachSq) { OutCenter = P; return true; }
		P = Mesh.GetBoneTransform(Bones3).Location;
		if ((BallPos - P).SizeSquared() <= ReachSq) { OutCenter = P; return true; }

		return false;
	}

	// Where this player wants to send the ball (set by AI each frame). The ball
	// uses this as the bounce direction on contact.
	FVector DesiredAim = FVector::ZeroVector;
	bool bHasAim = false;

	// Whether this player is allowed to touch the ball right now. Overridden by
	// AI so a player who made the team's last touch is "transparent" until a
	// different player (teammate or opponent) touches it — no double contacts.
	bool CanContactBall() const { return true; }

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

		float HeadZ = GetActorLocation().Z + PlayerHeight;
		bool bHigh = BallPos.Z > HeadZ;
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
			Type = (bHigh && bIsGrounded) ? EHitType::Hit_Set : EHitType::Hit_Bump;
		else
			Type = (!bIsGrounded && bHigh) ? EHitType::Hit_Spike
			     : (bHigh ? EHitType::Hit_Set : EHitType::Hit_Bump);     // grounded attack = shot
		bool bAttackTouch = !bBlockContact && MyTouches >= 2;

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
			// Arc by TOUCH NUMBER, not stroke: the SECOND ball is the pass the
			// attacker jumps on — with the floor target at the pin its arc must
			// peak ~490 to hang through the 350 strike zone (apex counts above
			// the higher endpoint, so grounding the target lowered every peak
			// by ~3m and the jump attack vanished). The reception keeps a
			// flatter arc for control.
			float Apex = (MyTouches == 1) ? 340.0f : 260.0f;
			FVector Pure = BallisticVelocity(BallPos, Target, Apex);
			OutVel = Pure + Reflected * 0.15f;
			if (CrossesNetPlane(BallPos, OutVel))
				OutVel = Pure;
		}

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

	// Called by gameplay code each time a contact happens. Sets which upper-body
	// hit montage the Anim Blueprint should blend in.
	protected void TriggerHit(EHitType Type, FVector WorldDir)
	{
		ReachDir = WorldDir.GetSafeNormal();
		CurrentHit = Type;      // a real contact is an event — no dwell gate
		GestureAge = 0.0f;
		HitAnimTimer = HitAnimDuration;
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

	// Horizontal acceleration rates (cm/s²). Ground values give a sprinter-like
	// first step (0→full in ~0.2s) and a decisive plant (full→0 in ~0.13s, sliding
	// ~30cm — matches the AI's 40cm plant radius). Air rate is weak on purpose.
	float GroundAccel = 2400.0f;
	float GroundDecel = 3400.0f;
	float AirAccel = 350.0f;

	// Ease PlayerVelocity.XY toward the requested input velocity.
	private void ApplyMoveInput(float DeltaTime)
	{
		FVector Cur = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0);
		FVector Target = FVector(MoveInput.X, MoveInput.Y, 0) * MoveSpeed;

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
	const float DiveSpeedMul = 1.75f;

	bool IsDiving() const { return DiveTimer > 0.0f; }
	bool CanDive() const { return bIsGrounded && DiveTimer <= 0.0f && DiveRecoverTimer <= 0.0f; }

	void StartDive(FVector WorldDir)
	{
		FVector Flat = FVector(WorldDir.X, WorldDir.Y, 0);
		if (Flat.SizeSquared() < 0.01f) return;
		DiveDir = Flat.GetSafeNormal();
		DiveTimer = DiveDuration;
		// Small hop so the lunge leaves the ground for a beat (scaled for the
		// heavy player gravity).
		PlayerVelocity.Z = 200.0f;
		bIsGrounded = false;
	}

	private void UpdateDive(float DeltaTime)
	{
		if (DiveTimer > 0.0f)
		{
			DiveTimer -= DeltaTime;
			// The dive owns the velocity and the facing while active.
			PlayerVelocity.X = DiveDir.X * MoveSpeed * DiveSpeedMul;
			PlayerVelocity.Y = DiveDir.Y * MoveSpeed * DiveSpeedMul;
			FacingDir = DiveDir;
			bHasFacing = true;
			ExtraCrouch = 1.0f;
			if (DiveTimer <= 0.0f)
				DiveRecoverTimer = DiveRecovery;
		}
		else if (DiveRecoverTimer > 0.0f)
		{
			DiveRecoverTimer -= DeltaTime;
			// Getting up: still low, easing back to standing.
			ExtraCrouch = Math::Max(ExtraCrouch, 0.85f * (DiveRecoverTimer / DiveRecovery));
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
	const float LoadedJumpVelocity = 660.0f;

	bool IsJumpLoading() const { return JumpLoadTimer > 0.0f; }

	void StartLoadedJump()
	{
		if (!bIsGrounded || JumpLoadTimer > 0.0f) return;
		// The plant: the gather brakes the run — momentum becomes height, and
		// the small residue drifts the body into the contact during the ascent.
		PlayerVelocity.X *= 0.25f;
		PlayerVelocity.Y *= 0.25f;
		JumpLoadTimer = JumpLoadDuration;
	}

	private void UpdateJumpLoad(float DeltaTime)
	{
		if (JumpLoadTimer <= 0.0f) return;
		if (!bIsGrounded) { JumpLoadTimer = 0.0f; return; }   // knocked airborne: cancel

		// Sink through the load — deepest right before the explosion.
		float Prog = 1.0f - JumpLoadTimer / JumpLoadDuration;
		ExtraCrouch = Math::Max(ExtraCrouch, 0.65f * Prog);

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

	private FLinearColor TeamColor() const
	{
		return (TeamSide == ETeam::Team_A)
			? FLinearColor(0.15f, 0.35f, 0.85f, 1)
			: FLinearColor(0.85f, 0.20f, 0.20f, 1);
	}

}
