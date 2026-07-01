// Side camera with soft ball-following

class ABeachVolleyballCamera : AActor
{
	UPROPERTY()
	UCameraComponent CameraComp;

	UPROPERTY()
	USpringArmComponent SpringArm;

	// Camera positioning
	FVector SideOffset = FVector(0, -1400, 350);  // Y offset for side view
	float FollowSpeed = 3.5f;                      // smoothing speed
	float BallWeightX = 0.4f;                      // how much ball X affects camera
	float BallWeightZ = 0.25f;                     // how much ball Z affects camera height

	FVector CurrentLookAt = FVector::ZeroVector;
	FVector TargetLookAt = FVector::ZeroVector;

	UPROPERTY()
	ABall Ball;

	void BeginPlay() override
	{
		// Position camera on side
		SetActorLocation(SideOffset);
		SetActorRotation(FRotator(0, 90, 0)); // face the court

		// Assign to player controller
		APlayerController PC = GetWorld().GetFirstPlayerController();
		if (PC != nullptr)
			PC.SetViewTarget(Cast<AActor>(this));

		FindBall();
	}

	void Tick(float DeltaTime) override
	{
		if (Ball == nullptr) FindBall();

		UpdateCameraPosition(DeltaTime);
	}

	private void UpdateCameraPosition(float DeltaTime)
	{
		// Base look-at point is court center
		FVector BaseLookAt = FVector(0, 0, 150);

		if (Ball != nullptr && Ball.bInPlay)
		{
			// Softly follow ball's X and Z position
			BaseLookAt.X = Ball.Position.X * BallWeightX;
			BaseLookAt.Z = 150 + Math::Max(0.0f, (Ball.Position.Z - 150) * BallWeightZ);
		}

		// Smooth interpolation
		CurrentLookAt = Math::VInterpTo(CurrentLookAt, BaseLookAt, DeltaTime, FollowSpeed);

		// Camera position: fixed Y offset, follow X and Z softly
		FVector CamPos = FVector(CurrentLookAt.X, SideOffset.Y, SideOffset.Z + CurrentLookAt.Z * 0.5f);
		SetActorLocation(CamPos);

		// Look at court center height
		FVector LookDir = (CurrentLookAt - CamPos).GetSafeNormal();
		FRotator LookRot = LookDir.Rotation();
		SetActorRotation(LookRot);
	}

	private void FindBall()
	{
		TArray<AActor> Found;
		GetAllActorsOfClass(ABall::StaticClass(), Found);
		if (Found.Num() > 0)
			Ball = Cast<ABall>(Found[0]);
	}
}
