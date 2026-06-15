// Human player - acts as AI until gamepad input is detected, then becomes player-controlled

class AHumanPlayer : AVolleyballPlayer
{
	UPROPERTY(DefaultComponent)
	UInputComponent ScriptInputComponent;

	UPROPERTY()
	ABall Ball;

	// True once the player has pressed anything on the gamepad
	bool bPlayerControlled = false;

	// AI state (used while bPlayerControlled == false)
	float ReactionDelay = 0.25f;
	float ReactionTimer = 0.0f;

	// Input axes (used when bPlayerControlled == true)
	float AxisForward = 0.0f;
	float AxisRight = 0.0f;

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		InitPlayer();
		TeamSide = ETeam::Team_A;

		CourtMinX = -900.0f;
		CourtMaxX = -5.0f;
		CourtMinY = -450.0f;
		CourtMaxY = 450.0f;

		// Bind input — only fires when this pawn is possessed
		ScriptInputComponent.BindAxis(n"MoveForward",   FInputAxisHandlerDynamicSignature(this, n"OnMoveForward"));
		ScriptInputComponent.BindAxis(n"MoveRight",     FInputAxisHandlerDynamicSignature(this, n"OnMoveRight"));
		ScriptInputComponent.BindAction(n"Jump",  EInputEvent::IE_Pressed, FInputActionHandlerDynamicSignature(this, n"OnJump"));
		ScriptInputComponent.BindAction(n"Pass",  EInputEvent::IE_Pressed, FInputActionHandlerDynamicSignature(this, n"OnPass"));
		ScriptInputComponent.BindAction(n"Set",   EInputEvent::IE_Pressed, FInputActionHandlerDynamicSignature(this, n"OnSet"));
		ScriptInputComponent.BindAction(n"Spike", EInputEvent::IE_Pressed, FInputActionHandlerDynamicSignature(this, n"OnSpike"));

	}

	UFUNCTION(BlueprintOverride)
	void Tick(float DeltaTime)
	{
		UpdatePlayer(DeltaTime);

		if (Ball == nullptr) FindBall();

		if (bPlayerControlled)
		{
			MovePlayer(FVector2D(AxisForward, AxisRight));
		}
		else
		{
			// AI fallback until gamepad wakes up
			RunAI(DeltaTime);
		}
	}

	// ---- Input handlers ----

	UFUNCTION()
	void OnMoveForward(float32 Value)
	{
		if (!bPlayerControlled && Math::Abs(Value) > 0.1f)
			TakeControl();
		AxisForward = Value;
	}

	UFUNCTION()
	void OnMoveRight(float32 Value)
	{
		if (!bPlayerControlled && Math::Abs(Value) > 0.1f)
			TakeControl();
		AxisRight = Value;
	}

	UFUNCTION()
	void OnJump(FKey Key)
	{
		if (!bPlayerControlled) TakeControl();
		Jump();
	}

	UFUNCTION()
	void OnPass(FKey Key)
	{
		if (!bPlayerControlled) TakeControl();
		if (Ball == nullptr) FindBall();
		TryPass(Ball);
	}

	UFUNCTION()
	void OnSet(FKey Key)
	{
		if (!bPlayerControlled) TakeControl();
		if (Ball == nullptr) FindBall();
		TrySet(Ball);
	}

	UFUNCTION()
	void OnSpike(FKey Key)
	{
		if (!bPlayerControlled) TakeControl();
		if (Ball == nullptr) FindBall();
		TrySpike(Ball);
	}

	private void TakeControl()
	{
		bPlayerControlled = true;
		Print("Gamepad detected - player control activated!");
	}

	// ---- Simple AI (mirrors AAIPlayer back-player logic) ----

	private void RunAI(float DeltaTime)
	{
		if (Ball == nullptr || !Ball.bInPlay) return;

		ReactionTimer += DeltaTime;
		if (ReactionTimer < ReactionDelay) return;

		FVector BallLoc = Ball.GetActorLocation();

		// Ball on opponent's side: retreat to ready position
		if (BallLoc.X > 0)
		{
			MoveTowardAI(FVector(-600.0f, 0, FloorZ + PlayerHeight), DeltaTime);
			return;
		}

		// Chase predicted ball position
		FVector Predicted = PredictBall(0.5f);
		Predicted.X = Math::Clamp(Predicted.X, CourtMinX + 50.0f, CourtMaxX - 50.0f);
		Predicted.Y = Math::Clamp(Predicted.Y, CourtMinY + 50.0f, CourtMaxY - 50.0f);
		MoveTowardAI(FVector(Predicted.X, Predicted.Y, FloorZ + PlayerHeight), DeltaTime);

		if (IsNearBall(Ball))
			TryPass(Ball);
	}

	private void MoveTowardAI(FVector Target, float DeltaTime)
	{
		FVector Dir = (Target - GetActorLocation());
		Dir.Z = 0;
		if (Dir.Size2D() > 10.0f)
			MovePlayer(FVector2D(Dir.GetSafeNormal2D().X, Dir.GetSafeNormal2D().Y));
		else
			MovePlayer(FVector2D::ZeroVector);

		// Only jump when ball is very close and high AND rising — not every frame
		if (Ball != nullptr && bIsGrounded && Dir.Size2D() < 120.0f)
		{
			FVector BallLoc = Ball.GetActorLocation();
			if (BallLoc.Z > PlayerHeight * 2.2f && Ball.BallVel.Z > 0)
				Jump();
		}
	}

	private FVector PredictBall(float TimeAhead) const
	{
		if (Ball == nullptr) return FVector::ZeroVector;
		FVector PPos = Ball.Position;
		FVector PVel = Ball.BallVel;
		float G = Ball.Gravity;
		float Dt = 0.05f;
		float T = 0;
		while (T < TimeAhead)
		{
			PVel.Z += G * Dt;
			PPos += PVel * Dt;
			T += Dt;
			if (PPos.Z <= Ball.FloorZ + Ball.BallRadius) break;
		}
		return PPos;
	}

	private void FindBall()
	{
		TArray<AActor> Found;
		GetAllActorsOfClass(ABall, Found);
		if (Found.Num() > 0)
			Ball = Cast<ABall>(Found[0]);
	}
}
