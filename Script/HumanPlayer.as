// Human player - WASD + Space + E (Pass) + Shift (Set) + F (Spike)

class AHumanPlayer : AVolleyballPlayer
{
	UPROPERTY()
	ABall Ball;

	// Input axis state
	float AxisForward = 0.0f;
	float AxisRight = 0.0f;

	void BeginPlay() override
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

	void SetupPlayerInputComponent(UInputComponent InputComp) override
	{
		Super::SetupPlayerInputComponent(InputComp);

		InputComp.BindAxis("MoveForward", this, n"OnMoveForward");
		InputComp.BindAxis("MoveRight", this, n"OnMoveRight");
		InputComp.BindAction("Jump", EInputEvent::IE_Pressed, this, n"OnJump");
		InputComp.BindAction("Pass", EInputEvent::IE_Pressed, this, n"OnPass");
		InputComp.BindAction("Set", EInputEvent::IE_Pressed, this, n"OnSet");
		InputComp.BindAction("Spike", EInputEvent::IE_Pressed, this, n"OnSpike");
	}

	void Tick(float DeltaTime) override
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
