// Human player - WASD + Space + E (Pass) + Shift (Set) + F (Spike)

class AHumanPlayer : AVolleyballPlayer
{
	UPROPERTY(DefaultComponent)
	UInputComponent ScriptInputComponent;

	UPROPERTY()
	ABall Ball;

	float AxisForward = 0.0f;
	float AxisRight = 0.0f;

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		Super::BeginPlay();
		TeamSide = ETeam::Team_A;

		CourtMinX = -900.0f;
		CourtMaxX = -5.0f;
		CourtMinY = -450.0f;
		CourtMaxY = 450.0f;

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
