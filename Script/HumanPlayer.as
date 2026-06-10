// Human player - keyboard + gamepad input

class AHumanPlayer : AVolleyballPlayer
{
	// Input component set up to handle input while this pawn is possessed.
	UPROPERTY(DefaultComponent)
	UInputComponent ScriptInputComponent;

	UPROPERTY()
	ABall Ball;

	// Input axis state
	float AxisForward = 0.0f;
	float AxisRight = 0.0f;

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		InitPlayer();
		TeamSide = ETeam::Team_A;

		// Set court bounds for left side
		CourtMinX = -900.0f;
		CourtMaxX = -5.0f;
		CourtMinY = -450.0f;
		CourtMaxY = 450.0f;

		// Bind keyboard + gamepad input (mappings live in DefaultInput.ini)
		ScriptInputComponent.BindAxis(n"MoveForward", FInputAxisHandlerDynamicSignature(this, n"OnMoveForward"));
		ScriptInputComponent.BindAxis(n"MoveRight", FInputAxisHandlerDynamicSignature(this, n"OnMoveRight"));
		ScriptInputComponent.BindAction(n"Jump", EInputEvent::IE_Pressed, FInputActionHandlerDynamicSignature(this, n"OnJump"));
		ScriptInputComponent.BindAction(n"Pass", EInputEvent::IE_Pressed, FInputActionHandlerDynamicSignature(this, n"OnPass"));
		ScriptInputComponent.BindAction(n"Set", EInputEvent::IE_Pressed, FInputActionHandlerDynamicSignature(this, n"OnSet"));
		ScriptInputComponent.BindAction(n"Spike", EInputEvent::IE_Pressed, FInputActionHandlerDynamicSignature(this, n"OnSpike"));
	}

	UFUNCTION(BlueprintOverride)
	void Tick(float DeltaTime)
	{
		UpdatePlayer(DeltaTime);
		MovePlayer(FVector2D(AxisForward, AxisRight));
	}

	UFUNCTION()
	void OnMoveForward(float32 Value) { AxisForward = Value; }

	UFUNCTION()
	void OnMoveRight(float32 Value) { AxisRight = Value; }

	UFUNCTION()
	void OnJump(FKey Key) { Jump(); }

	UFUNCTION()
	void OnPass(FKey Key)
	{
		if (Ball == nullptr) FindBall();
		TryPass(Ball);
	}

	UFUNCTION()
	void OnSet(FKey Key)
	{
		if (Ball == nullptr) FindBall();
		TrySet(Ball);
	}

	UFUNCTION()
	void OnSpike(FKey Key)
	{
		if (Ball == nullptr) FindBall();
		TrySpike(Ball);
	}

	private void FindBall()
	{
		TArray<AActor> Found;
		GetAllActorsOfClass(ABall::StaticClass(), Found);
		if (Found.Num() > 0)
			Ball = Cast<ABall>(Found[0]);
	}
}
