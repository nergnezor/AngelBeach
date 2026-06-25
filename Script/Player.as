// Base player pawn - movement, jump, hit actions, skeletal (Manny) body.
//
// Animation architecture (no engine fork needed):
//   - This script drives an AnimInstance (UVolleyballAnimInstance) by writing
//     BlueprintReadWrite properties every frame (Speed, bIsInAir, hit state...).
//   - An Animation Blueprint reparented to UVolleyballAnimInstance reads those
//     properties in its AnimGraph and runs a BLENDED state machine + blendspaces
//     (idle/walk/run blend on Speed, jump/fall, and hit montages per EHitType).
//   - To add a new move later: add an EHitType value + set it here, then add a
//     state/clip in the Anim Blueprint. Logic stays in code; blending in the graph.

// Which volleyball contact the player is performing (read by the Anim Blueprint
// to pick bump / set / spike upper-body animation).
enum EHitType
{
	Hit_None,
	Hit_Bump,   // bagger / dig — forearm pass, arms low together
	Hit_Set,    // handpass — overhead two-hand set
	Hit_Spike,  // attack — overhead one-arm swing
	Hit_Block,  // block — both hands up at the net, reaching over toward the ball
}

// Data carrier between gameplay code and the Animation Blueprint. Holds no
// animation logic itself — the AnimGraph (in the Anim BP) does the blending.
class UVolleyballAnimInstance : UAnimInstance
{
	// Locomotion
	UPROPERTY(BlueprintReadWrite) float Speed = 0.0f;        // horizontal speed (cm/s)
	UPROPERTY(BlueprintReadWrite) float ForwardSpeed = 0.0f; // signed, for fwd/bwd blend
	UPROPERTY(BlueprintReadWrite) float StrafeSpeed = 0.0f;  // signed, for left/right blend
	UPROPERTY(BlueprintReadWrite) bool  bIsMoving = false;

	// Air state
	UPROPERTY(BlueprintReadWrite) bool  bIsInAir = false;
	UPROPERTY(BlueprintReadWrite) float VerticalSpeed = 0.0f; // +up / -down, for jump/fall blend

	// Hit / contact state (drives which montage/state the Anim BP plays)
	UPROPERTY(BlueprintReadWrite) bool     bIsHitting = false;
	UPROPERTY(BlueprintReadWrite) EHitType HitType = EHitType::Hit_None;
	UPROPERTY(BlueprintReadWrite) float    HitAlpha = 0.0f;   // 0 -> 1 -> 0 swing envelope

	// --- Full Body IK effector targets (WORLD space) ----------------------
	// The Anim BP feeds these into a Full Body IK node. Code computes WHERE each
	// limb should be (relative to head/shoulders and the aim direction); the IK
	// node solves the joints so the hands/feet/hips land exactly there. This
	// replaces the old bone-space Modify Bone approach — no more guessing axes.
	//
	// IK is applied with weight IKAlpha (0 = pure animation, 1 = fully driven by
	// these targets), so arm gestures blend in/out smoothly over a contact.
	UPROPERTY(BlueprintReadWrite) float    IKAlpha = 0.0f;

	// Hands: where each palm should be, and which way it faces (for set/spike).
	UPROPERTY(BlueprintReadWrite) FVector  HandTargetR = FVector::ZeroVector;
	UPROPERTY(BlueprintReadWrite) FVector  HandTargetL = FVector::ZeroVector;
	UPROPERTY(BlueprintReadWrite) FRotator HandRotR = FRotator::ZeroRotator;
	UPROPERTY(BlueprintReadWrite) FRotator HandRotL = FRotator::ZeroRotator;

	// Elbow pole vectors: a world point the elbow points toward, so the IK picks
	// a natural elbow bend (forward for a set, down/out for a bump platform).
	UPROPERTY(BlueprintReadWrite) FVector  ElbowPoleR = FVector::ZeroVector;
	UPROPERTY(BlueprintReadWrite) FVector  ElbowPoleL = FVector::ZeroVector;

	// Lower body: hip height offset (negative = crouch) and dive hand plant.
	UPROPERTY(BlueprintReadWrite) float    CrouchAmount = 0.0f;  // 0..1, drives knee bend
	UPROPERTY(BlueprintReadWrite) bool     bDiving = false;      // play dive montage

	// Head look-at: a WORLD-space point the head should turn toward (the ball), fed
	// into a "Look At" skeletal-control node on the head bone in the Anim BP. Always
	// active (LookAlpha) so players keep their eyes on the ball.
	UPROPERTY(BlueprintReadWrite) FVector  LookTarget = FVector::ZeroVector;
	UPROPERTY(BlueprintReadWrite) float    LookAlpha = 0.0f;     // 0..1 look-at weight
}

class AVolleyballPlayer : APawn
{
	UPROPERTY(DefaultComponent, RootComponent)
	UCapsuleComponent Capsule;

	UPROPERTY(DefaultComponent, Attach = Capsule)
	USkeletalMeshComponent Mesh;

	float MoveSpeed = 450.0f;
	float JumpVelocity = 600.0f;
	float Gravity = -980.0f;

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
	private UVolleyballAnimInstance Anim;
	private EHitType CurrentHit = EHitType::Hit_None;
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
			// Content not found — keep player visible with a fallback box
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

		// Sand FX
		FVector Feet = FVector(NewLoc.X, NewLoc.Y, 0.0f);
		if (bIsGrounded && !bWasGrounded && FallSpeed > 120.0f)
		{
			float Strength = Math::Clamp(FallSpeed / 600.0f, 0.3f, 1.6f);
			if (Sand != nullptr) Sand.Footstep(Feet, Strength * 1.4f);
			if (Court != nullptr) Court.DeformSand(Feet, 24.0f, 4.0f + Strength * 6.0f);
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
		float HSpeed2 = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0).Size();
		FVector Want = FVector::ZeroVector;
		if (bHasFacing && FacingDir.SizeSquared() > 0.01f)
			Want = FVector(FacingDir.X, FacingDir.Y, 0);
		else if (HSpeed2 > 30.0f)
			Want = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0);

		if (Want.SizeSquared() > 0.01f)
		{
			FRotator Cur = GetActorRotation();
			float Alpha = Math::Clamp(8.0f * DeltaTime, 0.0f, 1.0f);
			SetActorRotation(Math::LerpShortestPath(Cur, Want.Rotation(), Alpha));
		}
		bHasFacing = false;   // AI must re-assert each frame; lapses otherwise

		UpdateAnimation(DeltaTime, HSpeed2);
	}

	// Feed movement + hit state into the AnimInstance. The Anim Blueprint reads
	// these and does the actual blending in its AnimGraph.
	private void UpdateAnimation(float DeltaTime, float HSpeed)
	{
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
		Anim.bIsMoving     = HSpeed > 40.0f;
		Anim.bIsInAir      = !bIsGrounded;
		Anim.VerticalSpeed = PlayerVelocity.Z;

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
		UpdateIKTargets(Shape);

		// Once the gesture has fully relaxed and we're no longer hitting/reaching,
		// release the hit type so the next contact can pick a fresh one.
		if (HitAnimTimer <= 0.0f && !bReaching && CurrentPose < 0.02f)
			CurrentHit = EHitType::Hit_None;

		// Per-attempt summary tracking: while gesturing, remember how close the hand
		// actually got to the ball. Emit ONE line when the attempt ends — far less
		// noise than per-frame, and it answers the real question: did the hand reach
		// the ball, and did it score a contact?
		if (CurrentPose > 0.05f)
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
				float Catch = ArmContactRadius + 10.5f;
				Log("ATTEMPT type=" + int(CurrentHit)
					+ " closestHand=" + int(AttemptClosest)
					+ " catch=" + int(Catch)
					+ " | bodyHoriz=" + int(AttemptHoriz)
					+ " ballVsHead=" + int(AttemptVert)
					+ " pose=" + int(AttemptPose * 100)
					+ " facing=" + int(AttemptFacing * 100)
					+ " | handVsTarget=" + int(AttemptHandVsTarget)
					+ " targetVsBall=" + int(AttemptTargetVsBall)
					+ (AttemptClosest <= Catch ? "  -> SHOULD HIT" : "  -> MISS"));
			}
			bAttemptActive = false;
			AttemptClosest = 99999.0f;
		}

		// Reaching is re-asserted each frame by the AI; clear it so it lapses
		// when the AI stops asking.
		bReaching = false;
	}

	private bool bAttemptActive = false;
	private float AttemptClosest = 99999.0f;
	private float AttemptHoriz = 0.0f;
	private float AttemptVert = 0.0f;
	private float AttemptPose = 0.0f;
	private float AttemptFacing = 0.0f;
	private float AttemptHandVsTarget = 0.0f;
	private float AttemptTargetVsBall = 0.0f;

	private float CurrentPose = 0.0f;   // smoothed arm-pose SHAPE weight (ready->contact)
	private float IKWeight = 0.0f;      // smoothed IK node Alpha (how much IK applies)

	// AI sets this each frame while preparing to play the ball, with the hit type
	// it intends, so the arms extend toward the ball before contact.
	bool bReaching = false;
	void Reach(EHitType Type)
	{
		bReaching = true;
		if (HitAnimTimer <= 0.0f)   // don't override an active swing
			CurrentHit = Type;
	}

	// Distance (cm) at which any player auto-reaches toward the ball. Kept tight so
	// players don't flail at a ball that's still metres away — the AI drives the
	// deliberate reach as it closes in; this is just a safety net at true arm range.
	float AutoReachDistance = 130.0f;

	// Reach for the ball automatically when it's near and I may legally play it.
	// Hit type is picked from the ball's height relative to my body.
	private void AutoReachForBall()
	{
		if (!CanContactBall()) return;
		ABall B = GetWorldBall();
		if (B == nullptr || !B.bInPlay) return;

		float Dist = (GetActorLocation() - B.Position).Size();
		if (Dist > AutoReachDistance) return;

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

	// Compute WORLD-space IK targets for the current hit type. The Anim BP feeds
	// these into a Full Body IK node, which solves the joints so the hands land
	// exactly where we ask. Targets are anchored to the head/shoulder bones (so
	// they track the body as it moves/jumps) and oriented toward AimDir — the
	// direction the player wants to send the ball.
	//
	// 'Blend' (0..1) is the gesture weight: at 0 the hands sit at a relaxed ready
	// spot, at 1 they're fully at the contact pose. We lerp ready->contact so the
	// motion eases in. IKAlpha (set by caller) controls how much the IK overrides
	// the base animation.
	private void UpdateIKTargets(float Blend)
	{
		if (Mesh == nullptr) return;

		// Body anchors from the actual skeleton (track jumps, lean, run).
		FVector Head  = Mesh.GetBoneTransform(n"head").Location;
		FVector ShR   = Mesh.GetBoneTransform(n"upperarm_r").Location;
		FVector ShL   = Mesh.GetBoneTransform(n"upperarm_l").Location;
		FVector Fwd   = GetActorForwardVector();
		FVector Right = GetActorRightVector();
		FVector Up    = FVector(0, 0, 1);

		// Where the player is sending the ball. Falls back to "up and forward".
		FVector Aim = bHasAim
			? (DesiredAim - Head).GetSafeNormal()
			: (Fwd * 0.4f + Up).GetSafeNormal();
		FVector AimFlat = FVector(Aim.X, Aim.Y, 0).GetSafeNormal();
		if (AimFlat.SizeSquared() < 0.01f) AimFlat = Fwd;

		// Where the BALL is — the hands reach straight toward it, clamped to arm's
		// length from the chest so the IK stays solvable. The player turns to face
		// the ball (FaceBall in the AI), so this naturally ends up in front. We do
		// NOT re-project onto the facing axes — that pushed the hand forward when the
		// ball was to the side, making the hand end up FARTHER from the ball than the
		// body (the bug the debug meter caught: closestHand > bodyHoriz).
		FVector ChestMid = (ShR + ShL) * 0.5f;
		FVector BallContact = ChestMid + Fwd * 35.0f + Up * 5.0f;  // default if no ball
		{
			ABall B = GetWorldBall();
			if (B != nullptr && B.bInPlay)
			{
				FVector ToBall = B.Position - ChestMid;
				float ArmReach = 110.0f;                  // shoulder->hand max (cm)
				if (ToBall.Size() > ArmReach)
					BallContact = ChestMid + ToBall.GetSafeNormal() * ArmReach;
				else
					BallContact = B.Position;             // ball within reach: aim right at it
			}
		}

		// Relaxed ready position: hands hang slightly forward at the sides.
		FVector ReadyR = ShR + Fwd * 18.0f - Up * 35.0f;
		FVector ReadyL = ShL + Fwd * 18.0f - Up * 35.0f;

		FVector ContactR;
		FVector ContactL;
		FRotator PalmR = FRotator::ZeroRotator;
		FRotator PalmL = FRotator::ZeroRotator;
		FVector PoleR;
		FVector PoleL;
		float Crouch = 0.0f;

		if (CurrentHit == EHitType::Hit_Bump)
		{
			// Bagger/dig: arms STRAIGHT and flat, hands JOINED under the ball so the
			// forearm platform meets it. Both hands converge on the ball contact,
			// pulled a little low so the platform is beneath the ball.
			FVector Platform = BallContact - Up * 12.0f;
			ContactR = Platform - Right * 6.0f;
			ContactL = Platform + Right * 6.0f;
			// Elbows pulled DOWN and back so the arms lock out straight.
			PoleR = ContactR - Up * 45.0f - Fwd * 25.0f;
			PoleL = ContactL - Up * 45.0f - Fwd * 25.0f;
			// Forearm platform faces up toward the aim arc.
			PalmR = (AimFlat * 0.5f + Up).GetSafeNormal().Rotation();
			PalmL = PalmR;
			Crouch = 0.6f;
		}
		else if (CurrentHit == EHitType::Hit_Set)
		{
			// Fingerpass/set: hands form a CUP under/around the ball above the brow,
			// elbows forward. On contact (Blend->1) the palms push up-forward toward
			// the aim, as if shoving the ball away.
			FVector Cup = BallContact - Up * 6.0f;               // hands just under the ball
			FVector Push = (AimFlat * 0.6f + Up * 0.8f).GetSafeNormal() * 14.0f;
			ContactR = Cup - Right * 11.0f + Push * Blend;
			ContactL = Cup + Right * 11.0f + Push * Blend;
			// Elbows point FORWARD (and slightly out) — the set's signature shape.
			PoleR = ShR + Fwd * 40.0f - Right * 10.0f;
			PoleL = ShL + Fwd * 40.0f + Right * 10.0f;
			PalmR = (AimFlat * 0.5f + Up).GetSafeNormal().Rotation();
			PalmL = PalmR;
			Crouch = 0.2f;
		}
		else if (CurrentHit == EHitType::Hit_Spike)
		{
			// Spike, in two phases driven by Blend (0 = cock, 1 = strike):
			//  - LEFT arm aims at the ball throughout (points/tracks it before the hit).
			//  - RIGHT hand starts cocked just OUTSIDE the right cheek, then swings
			//    forward/up to strike with a near-straight arm ABOVE and slightly in
			//    FRONT of the right shoulder.
			// Left arm: extend toward the ball (clamped to arm reach), tracking it.
			FVector ToBallL = (BallContact - ShL);
			float ReachL = 95.0f;
			if (ToBallL.Size() > ReachL) ToBallL = ToBallL.GetSafeNormal() * ReachL;
			ContactL = ShL + ToBallL;
			PoleL = ShL + ToBallL * 0.4f - Up * 15.0f;   // elbow softly under the aim line
			PalmL = ToBallL.GetSafeNormal().Rotation();

			// Right hand cocked outside the right cheek (head height, out to the right,
			// slightly back), then driving to a strike point above + in front of the
			// right shoulder, reaching toward the ball's height.
			FVector Cheek  = Head + Right * 22.0f + Up * 2.0f - Fwd * 8.0f;   // outside right cheek
			float StrikeUp = Math::Max(35.0f, BallContact.Z - ShR.Z);         // reach up to ball
			FVector Strike = ShR + Up * StrikeUp + Fwd * 22.0f + Right * 6.0f; // above & front of R shoulder
			ContactR = Cheek + (Strike - Cheek) * Blend;
			// Elbow stays high and back early, leading the hand on the swing.
			PoleR = ContactR + Up * 25.0f - Fwd * 30.0f + Right * 10.0f;
			// Palm faces the aim/down as it comes over the top.
			PalmR = (AimFlat * 0.5f + Up * (1.0f - Blend) - Up * 0.3f * Blend).GetSafeNormal().Rotation();
			Crouch = 0.0f;
		}
		else if (CurrentHit == EHitType::Hit_Block)
		{
			// Block: both hands reach UP and toward the ball, as high/close as the
			// arms allow, angled so the palms face DOWN into the middle of the
			// opponent's court (DesiredAim) — that's where we want to deflect a spike.
			// Hands press together (penetrate the net) rather than spread wide.
			FVector ToBall = BallContact - ChestMid;
			float ArmUp = 95.0f;                         // near-full vertical reach
			FVector Up95 = ToBall;
			if (Up95.Size() > ArmUp) Up95 = Up95.GetSafeNormal() * ArmUp;
			FVector BlockMid = ChestMid + Up95;          // both hands converge here, high
			ContactR = BlockMid + Right * 9.0f;          // hands close together
			ContactL = BlockMid - Right * 9.0f;
			// Elbows high and slightly forward so the arms form a firm wall.
			PoleR = ContactR + Fwd * 25.0f - Up * 5.0f;
			PoleL = ContactL + Fwd * 25.0f - Up * 5.0f;
			// Palms face down-and-toward the aim (middle of opponent court) to push
			// the blocked ball back down into their court.
			FVector PalmDir = (AimFlat * 0.6f - Up).GetSafeNormal();
			PalmR = PalmDir.Rotation();
			PalmL = PalmDir.Rotation();
			Crouch = 0.0f;
		}
		else
		{
			ContactR = ReadyR; ContactL = ReadyL;
			PoleR = ShR - Up * 40.0f; PoleL = ShL - Up * 40.0f;
		}

		// Ease from ready to the contact pose by the gesture weight. The spike builds
		// its own Cheek->Strike motion into ContactR/L via Blend, so it should NOT be
		// re-lerped from the ready pose (that would start the hand at the hip instead
		// of cocked at the cheek). Other hits ease from ready as usual.
		if (CurrentHit == EHitType::Hit_Spike || CurrentHit == EHitType::Hit_Block)
		{
			Anim.HandTargetR = ContactR;
			Anim.HandTargetL = ContactL;
		}
		else
		{
			Anim.HandTargetR = ReadyR + (ContactR - ReadyR) * Blend;
			Anim.HandTargetL = ReadyL + (ContactL - ReadyL) * Blend;
		}
		Anim.ElbowPoleR  = PoleR;
		Anim.ElbowPoleL  = PoleL;
		Anim.HandRotR    = PalmR;
		Anim.HandRotL    = PalmL;
		Anim.CrouchAmount = Crouch * Blend;
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

	// Called by the ball when it physically touches this player. The ball gives
	// its current velocity; we return the post-contact velocity using REAL
	// collision physics: reflect the incoming velocity about the contact normal
	// (with restitution) and add the velocity imparted by the arm swing. The arm
	// is angled toward the player's aim, so a real reflection sends it there —
	// no teleporting to a fixed speed/direction.
	FVector OnBallContact(FVector BallPos, FVector BallVelIn, FVector Center)
	{
		// Choose hit type from where the ball meets the body, relative to the
		// player's own height (head ~ feet + 2*PlayerHeight).
		float HeadZ = GetActorLocation().Z + PlayerHeight;
		EHitType Type;
		if (BallPos.Z > HeadZ)
			Type = bIsGrounded ? EHitType::Hit_Set : EHitType::Hit_Spike;
		else
			Type = EHitType::Hit_Bump;

		// Contact normal: the surface the ball bounces off. Base it on the real
		// geometric normal (ball relative to body) but tilt it toward the aim so
		// the player "angles" their arms like a real player would.
		FVector GeoNormal = (BallPos - Center).GetSafeNormal();
		if (GeoNormal.SizeSquared() < 0.01f) GeoNormal = FVector(0, 0, 1);

		FVector AimDir;
		float Sign = (TeamSide == ETeam::Team_A) ? 1.0f : -1.0f;
		if (bHasAim)
			AimDir = (DesiredAim - BallPos).GetSafeNormal();
		else
			AimDir = FVector(Sign * 0.4f, 0, 1.0f).GetSafeNormal();

		// Blend geometric normal with aim (how much the player controls the angle)
		FVector Normal = (GeoNormal * 0.35f + AimDir * 0.65f).GetSafeNormal();

		// Reflect incoming velocity about the contact normal with restitution.
		// (A controlled contact kills most incoming speed; the swing adds power.)
		float ContactRestitution = 0.35f;
		float VDotN = BallVelIn.DotProduct(Normal);
		FVector Reflected = BallVelIn - Normal * (2.0f * VDotN);
		Reflected *= ContactRestitution;

		// Arm swing impulse along the aim direction — this is the "hit power".
		// Different contacts impart different energy, like real technique.
		float SwingPower;
		if      (Type == EHitType::Hit_Spike) SwingPower = 1150.0f;
		else if (Type == EHitType::Hit_Set)   SwingPower = 520.0f;
		else                                  SwingPower = 600.0f;  // bump

		FVector SwingDir = AimDir;
		if (Type == EHitType::Hit_Spike) SwingDir.Z = Math::Min(SwingDir.Z, -0.2f);
		else                             SwingDir.Z = Math::Max(SwingDir.Z, 0.45f);
		SwingDir = SwingDir.GetSafeNormal();

		FVector OutVel = Reflected + SwingDir * SwingPower;

		TriggerHit(Type, SwingDir);
		RegisterHit(GetWorldBall());
		bHasAim = false;
		return OutVel;
	}

	// The ball passes itself for touch registration; we keep a cached ref.
	private ABall CachedBall;
	private ABall GetWorldBall()
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
		CurrentHit = Type;
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
		// In the air we have almost no horizontal control — a jump (block/spike) is
		// essentially vertical. This stops players drifting/swimming around mid-jump,
		// which looked unnatural and made blocks/spikes miss. Keep a small amount of
		// steering so they aren't completely locked.
		float Control = bIsGrounded ? 1.0f : AirControl;
		PlayerVelocity.X = Input.X * MoveSpeed * Control;
		PlayerVelocity.Y = Input.Y * MoveSpeed * Control;
	}

	// Fraction of horizontal move speed available while airborne (0 = none).
	float AirControl = 0.15f;

	UFUNCTION(BlueprintCallable)
	void Jump()
	{
		if (bIsGrounded)
		{
			PlayerVelocity.Z = JumpVelocity;
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
