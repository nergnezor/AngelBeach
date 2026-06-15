// Base player pawn - movement, jump, hit actions, skeletal (Manny) body
// Animation is driven from script via Single Node mode: we swap the active
// animation sequence based on movement state (idle / run / jump / fall).

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

	// Animation clips (loaded once in SetupMesh)
	private UAnimSequence AnimIdle;
	private UAnimSequence AnimRun;
	private UAnimSequence AnimJump;
	private UAnimSequence AnimFall;

	// Which clip is currently playing, so we only switch when state changes
	private int CurrentAnim = -1;  // 0 idle, 1 run, 2 jump, 3 fall

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

		// Drive animation directly from script (no Anim Blueprint needed)
		Mesh.SetAnimationMode(EAnimationMode::AnimationSingleNode);

		AnimIdle = LoadAnim("MM_Idle");
		AnimRun  = LoadAnim("MM_Run_Fwd");
		AnimJump = LoadAnim("MM_Jump");
		AnimFall = LoadAnim("MM_Fall_Loop");

		SetAnim(0);  // start in idle

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

	private UAnimSequence LoadAnim(FString Clip) const
	{
		FString Path = "/MoverExamples/Characters/Mannequins/Animations/Manny/"
			+ Clip + "." + Clip;
		return Cast<UAnimSequence>(LoadObject(nullptr, Path));
	}

	// Switch the active single-node animation, looping locomotion/fall, one-shot jump
	private void SetAnim(int Which)
	{
		if (Mesh == nullptr || Which == CurrentAnim) return;
		CurrentAnim = Which;

		UAnimSequence Seq;
		bool bLoop = true;
		if      (Which == 0) Seq = AnimIdle;
		else if (Which == 1) Seq = AnimRun;
		else if (Which == 2) { Seq = AnimJump; bLoop = false; }
		else                 Seq = AnimFall;

		if (Seq == nullptr) return;
		Mesh.SetAnimation(Seq);
		Mesh.SetPlayRate(1.0f);
		Mesh.Play(bLoop);
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

		UpdateAnimation(HSpeed2);
	}

	private void UpdateAnimation(float HSpeed)
	{
		if (Mesh == nullptr) return;

		if (!bIsGrounded)
		{
			// Jump anim on the way up, fall-loop once descending
			SetAnim(PlayerVelocity.Z > 0.0f ? 2 : 3);
		}
		else if (HSpeed > 40.0f)
		{
			// Run; scale play rate with speed so slow shuffles read slower
			SetAnim(1);
			Mesh.SetPlayRate(Math::Clamp(HSpeed / MoveSpeed, 0.5f, 1.4f));
		}
		else
		{
			SetAnim(0);
		}
	}

	protected void TriggerReach(FVector WorldDir)
	{
		ReachDir = WorldDir.GetSafeNormal();
		ReachTimer = 0.35f;
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
		TriggerReach(FVector(0, 0, 1));
		RegisterHit(Ball);
	}

	UFUNCTION(BlueprintCallable)
	void TrySet(ABall Ball)
	{
		if (Ball == nullptr || !bCanHit || !IsNearBall(Ball)) return;
		float XDir = (TeamSide == ETeam::Team_A) ? 1.0f : -1.0f;
		FVector Dir = FVector(XDir * 0.65f, 0, 0.76f).GetSafeNormal();
		Ball.HitBall(Dir, 620.0f);
		TriggerReach(FVector(XDir * 0.5f, 0, 1.0f));
		RegisterHit(Ball);
	}

	UFUNCTION(BlueprintCallable)
	void TrySpike(ABall Ball)
	{
		if (Ball == nullptr || !bCanHit || !IsNearBall(Ball)) return;
		float XDir = (TeamSide == ETeam::Team_A) ? 1.0f : -1.0f;
		FVector ToNet = FVector(XDir, 0, -0.35f).GetSafeNormal();
		Ball.HitBall(ToNet, 1300.0f);
		TriggerReach(FVector(XDir * 0.4f, 0, 1.0f));
		RegisterHit(Ball);
	}

	void HitToward(FVector Dir, float Speed, ABall Ball)
	{
		if (Ball == nullptr || !bCanHit) return;
		Ball.HitBall(Dir, Speed);
		TriggerReach(Dir);
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
