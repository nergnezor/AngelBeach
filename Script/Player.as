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

	// Hit / contact state (upper-body montage selection)
	UPROPERTY(BlueprintReadWrite) bool     bIsHitting = false;
	UPROPERTY(BlueprintReadWrite) EHitType HitType = EHitType::Hit_None;
	UPROPERTY(BlueprintReadWrite) float    HitAlpha = 0.0f;   // 0 -> 1 -> 0 swing envelope

	// Ready-to-use arm rotations computed per hit type in code, so the Anim
	// Blueprint plugs them STRAIGHT into a Transform (Modify) Bone Rotation pin
	// — no Make Rotator, no per-type branching needed in the graph.
	UPROPERTY(BlueprintReadWrite) FRotator ArmRotR = FRotator::ZeroRotator;
	UPROPERTY(BlueprintReadWrite) FRotator ArmRotL = FRotator::ZeroRotator;
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

		USkeletalMesh SkMesh = Cast<USkeletalMesh>(LoadObject(nullptr,
			"/MoverExamples/Characters/Mannequins/Meshes/SKM_Manny_Simple.SKM_Manny_Simple"));
		if (SkMesh == nullptr)
		{
			// Plugin content not mounted — keep player visible with a fallback box
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

		// Face the direction of travel so the locomotion animation reads correctly
		float HSpeed2 = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0).Size();
		if (HSpeed2 > 30.0f)
		{
			FRotator Want = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0).Rotation();
			FRotator Cur = GetActorRotation();
			float Alpha = Math::Clamp(10.0f * DeltaTime, 0.0f, 1.0f);
			SetActorRotation(Math::LerpShortestPath(Cur, Want, Alpha));
		}

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

		Anim.HitAlpha = CurrentPose;
		UpdateArmPose(CurrentPose);

		// Once the gesture has fully relaxed and we're no longer hitting/reaching,
		// release the hit type so the next contact can pick a fresh one.
		if (HitAnimTimer <= 0.0f && !bReaching && CurrentPose < 0.02f)
			CurrentHit = EHitType::Hit_None;

		if (bDebugHit && (bReaching || CurrentPose > 0.05f))
			LogArmGeometry();

		// Reaching is re-asserted each frame by the AI; clear it so it lapses
		// when the AI stops asking.
		bReaching = false;
	}

	// Reads the ACTUAL bone world positions after the AnimGraph applied our
	// rotations, so we can "see" where the right arm physically points: the
	// hand's offset from the shoulder, in the player's local frame.
	//   fwd  = +X (in front of chest), up = +Z, side = +Y (right)
	private void LogArmGeometry()
	{
		if (Mesh == nullptr) return;
		FVector Shoulder = Mesh.GetBoneTransform(n"upperarm_r").Location;
		FVector Hand     = Mesh.GetBoneTransform(n"hand_r").Location;
		FVector Off      = Hand - Shoulder;                 // world-space arm vector

		// Express in the player's own frame so values are intuitive.
		FVector Local = GetActorTransform().InverseTransformVector(Off);
		FString Tag = bAxisProbe ? ("PROBE " + ProbeAxisLabel) : ("type=" + int(CurrentHit));
		Log("ARM " + Tag
			+ " | hand vs shoulder  fwd=" + int(Local.X)
			+ " side=" + int(Local.Y)
			+ " up=" + int(Local.Z)
			+ "  (sent Pitch=" + int(Anim.ArmRotR.Pitch)
			+ " Yaw=" + int(Anim.ArmRotR.Yaw)
			+ " Roll=" + int(Anim.ArmRotR.Roll) + ")");
	}

	private float CurrentPose = 0.0f;   // smoothed arm-pose weight

	// AI sets this each frame while preparing to play the ball, with the hit type
	// it intends, so the arms extend toward the ball before contact.
	bool bReaching = false;
	void Reach(EHitType Type)
	{
		bReaching = true;
		if (HitAnimTimer <= 0.0f)   // don't override an active swing
			CurrentHit = Type;
	}

	// Distance (cm) at which any player starts reaching arms toward the ball.
	float AutoReachDistance = 220.0f;

	// Reach for the ball automatically when it's near and I may legally play it.
	// Hit type is picked from the ball's height relative to my body.
	private void AutoReachForBall()
	{
		if (!CanContactBall()) return;
		ABall B = GetWorldBall();
		if (B == nullptr || !B.bInPlay) return;

		float Dist = (GetActorLocation() - B.Position).Size();
		if (Dist > AutoReachDistance) return;

		float HeadZ = GetActorLocation().Z + PlayerHeight;
		EHitType Type;
		if (B.Position.Z > HeadZ)
			Type = bIsGrounded ? EHitType::Hit_Set : EHitType::Hit_Spike;
		else
			Type = EHitType::Hit_Bump;

		Reach(Type);
	}

	// Compute target arm rotations for the current hit type, scaled by the swing
	// envelope. The Anim BP feeds ArmRotR/ArmRotL straight into Modify Bone.
	//
	// Axis mapping on Manny's upperarm bones (Component Space, from probe data):
	//   Pitch+90  => arm swings forward (fwd+30), barely lifts (up≈0)
	//   Yaw+90    => arm swings inward across chest (side-30), slight lift
	//   Roll-90   => arm lifts straight up (up+30), forward component negative
	//   Roll+90   => arm drops straight down (up-30)
	//
	// Bump: arms forward + slightly down  => Pitch+70, Roll+20
	// Set:  arms straight up overhead     => Roll-90 (both)
	// Spike: right arm up then drives fwd => Roll-90 at reach, Pitch+90 at swing peak
	//        left arm balance             => Roll-50
	private void UpdateArmPose(float Swing)
	{
		float RollR = 0; float PitchR = 0; float YawR = 0;
		float RollL = 0; float PitchL = 0; float YawL = 0;

		if (CurrentHit == EHitType::Hit_Bump)
		{
			// Bagger/dig: arms forward-down in front, wrists together.
			// Pitch pushes arm forward; small Roll+ tips it slightly downward.
			PitchR = 70.0f;  YawR = -15.0f; RollR =  20.0f;
			PitchL = 70.0f;  YawL =  15.0f; RollL = -20.0f;
		}
		else if (CurrentHit == EHitType::Hit_Set)
		{
			// Handpass/set: both arms up overhead, elbows bent outward.
			// Roll-90 lifts arm straight up; Yaw opens elbows out.
			RollR = -90.0f; YawR = -20.0f;
			RollL =  90.0f; YawL =  20.0f;
		}
		else if (CurrentHit == EHitType::Hit_Spike)
		{
			// Spike: right arm cocks up (Roll-90) while Swing is low, then
			// drives forward (Pitch+80) as Swing peaks. Apply Swing directly
			// per component so the transition is smooth.
			Anim.ArmRotR = FRotator(
				 80.0f * Swing,           // Pitch: drives arm forward at peak
				-10.0f * Swing,           // Yaw: slight inward at peak
				-90.0f * (1.0f - Swing)); // Roll: arm raised at start, neutral at peak
			// Left arm lifts for balance
			Anim.ArmRotL = FRotator(0.0f, 20.0f * Swing, 50.0f * Swing);
			return;
		}

		Anim.ArmRotR = FRotator(PitchR * Swing, YawR * Swing, RollR * Swing);
		Anim.ArmRotL = FRotator(PitchL * Swing, YawL * Swing, RollL * Swing);
	}

	bool bAxisProbe = false;
	private FString ProbeAxisLabel = "";

	// --- Physical ball contact ---------------------------------------------
	// The ball calls these. The player no longer teleports the ball's velocity;
	// instead the ball bounces off the player's arm region, and we trigger the
	// matching animation + register the touch.

	// Ball only bounces off hands and forearms. Each is a small sphere centered
	// on the bone, in world space. Radius is how thick the limb is for contact.
	float ArmContactRadius = 18.0f;   // forearm/hand thickness (cm)

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
		PlayerVelocity.X = Input.X * MoveSpeed;
		PlayerVelocity.Y = Input.Y * MoveSpeed;
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
