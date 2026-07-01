// Human player - WASD + Space + E (Pass) + Shift (Set) + F (Spike)

class AHumanPlayer : AVolleyballPlayer
{
	UPROPERTY()
	ABall Ball;

	// Input axis state
	float AxisForward = 0.0f;
	float AxisRight = 0.0f;

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		Super::BeginPlay();
		TeamSide = ETeam::Team_A;

		// Set court bounds for left side
		CourtMinX = -900.0f;
		CourtMaxX = -5.0f;
		CourtMinY = -450.0f;
		CourtMaxY = 450.0f;

		// Enable input
		APlayerController PC = Cast<APlayerController>(GetController());
		if (PC != nullptr)
			EnableInput(PC);
	}

	UFUNCTION(BlueprintOverride)
	void SetupPlayerInputComponent(UInputComponent InputComp)
	{
		FInputAxisHandlerDynamicSignature AxisFwd;
		AxisFwd.BindUFunction(this, n"OnMoveForward");
		InputComp.BindAxis(n"MoveForward", AxisFwd);

		FInputAxisHandlerDynamicSignature AxisRight;
		AxisRight.BindUFunction(this, n"OnMoveRight");
		InputComp.BindAxis(n"MoveRight", AxisRight);

		FInputActionHandlerDynamicSignature ActJump;
		ActJump.BindUFunction(this, n"OnJump");
		InputComp.BindAction(n"Jump", EInputEvent::IE_Pressed, ActJump);

		FInputActionHandlerDynamicSignature ActPass;
		ActPass.BindUFunction(this, n"OnPass");
		InputComp.BindAction(n"Pass", EInputEvent::IE_Pressed, ActPass);

		FInputActionHandlerDynamicSignature ActSet;
		ActSet.BindUFunction(this, n"OnSet");
		InputComp.BindAction(n"Set", EInputEvent::IE_Pressed, ActSet);

		FInputActionHandlerDynamicSignature ActSpike;
		ActSpike.BindUFunction(this, n"OnSpike");
		InputComp.BindAction(n"Spike", EInputEvent::IE_Pressed, ActSpike);
	}

	UFUNCTION(BlueprintOverride)
	void Tick(float DeltaTime)
	{
		Super::Tick(DeltaTime);
		MovePlayer(FVector2D(AxisForward, AxisRight));
	}

	UFUNCTION()
	void OnMoveForward(float Value) { AxisForward = Value; }

	UFUNCTION()
	void OnMoveRight(float Value) { AxisRight = Value; }

	UFUNCTION()
	void OnJump() { Jump(); }

	UFUNCTION()
	void OnPass()
	{
		if (Ball == nullptr) FindBall();
		TryPass(Ball);
	}

	UFUNCTION()
	void OnSet()
	{
		if (Ball == nullptr) FindBall();
		TrySet(Ball);
	}

	UFUNCTION()
	void OnSpike()
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
