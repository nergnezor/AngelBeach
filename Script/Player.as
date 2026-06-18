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
	private float HitAnimDuration = 0.45f;  // hit pose blends out over this time

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
		// Decay the hit blend so the upper-body montage eases back out
		if (HitAnimTimer > 0.0f)
		{
			HitAnimTimer -= DeltaTime;
			if (HitAnimTimer <= 0.0f)
			{
				HitAnimTimer = 0.0f;
				CurrentHit = EHitType::Hit_None;
			}
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

		Anim.bIsHitting = HitAnimTimer > 0.0f;
		Anim.HitType    = CurrentHit;

		// Swing envelope: 0 at start -> 1 at mid-contact -> 0 at end, so the arm
		// swings up into the hit and back down rather than snapping.
		float Progress = (HitAnimDuration > 0.0f)
			? 1.0f - Math::Clamp(HitAnimTimer / HitAnimDuration, 0.0f, 1.0f)
			: 0.0f;
		float Swing = Math::Sin(Progress * PI);   // 0..1..0
		Anim.HitAlpha = Swing;

		UpdateArmPose(Swing);
	}

	// Compute target arm rotations for the current hit type, scaled by the swing
	// envelope. The Anim BP feeds ArmRotR/ArmRotL straight into Modify Bone.
	// Rotator is (Pitch, Yaw, Roll).
	private void UpdateArmPose(float Swing)
	{
		// Neutral when not hitting
		float PitchR = 0; float YawR = 0; float PitchL = 0; float YawL = 0;

		if (CurrentHit == EHitType::Hit_Bump)
		{
			// Bagger/dig: both arms straight down-forward, clasped together low
			PitchR = 35.0f;  YawR = -10.0f;
			PitchL = 35.0f;  YawL =  10.0f;
		}
		else if (CurrentHit == EHitType::Hit_Set)
		{
			// Handpass/set: both arms up overhead
			PitchR = 165.0f; YawR = -15.0f;
			PitchL = 165.0f; YawL =  15.0f;
		}
		else if (CurrentHit == EHitType::Hit_Spike)
		{
			// Spike: right arm whips from high overhead down — drive purely by
			// swing so it reads as a strike (up at start of swing, down at peak)
			PitchR = 180.0f;
			// left arm lifts for balance
			PitchL = 120.0f; YawL = 20.0f;
		}

		Anim.ArmRotR = FRotator(PitchR * Swing, YawR * Swing, 0.0f);
		Anim.ArmRotL = FRotator(PitchL * Swing, YawL * Swing, 0.0f);
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

	private void RegisterHit(ABall Ball)
	{
		bCanHit = false; HitTimer = 0;
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS != nullptr)
		{
			bool bValid = GS.RegisterTouch(TeamSide);
			if (!bValid && GM != nullptr) GM.OnTouchViolation(TeamSide);
		}
	}

	private FLinearColor TeamColor() const
	{
		return (TeamSide == ETeam::Team_A)
			? FLinearColor(0.15f, 0.35f, 0.85f, 1)
			: FLinearColor(0.85f, 0.20f, 0.20f, 1);
	}

}
