// Side camera with soft ball-following

// Extends APawn so Tick is enabled (AActor has bCanEverTick=false by default).
class ABeachVolleyballCamera : APawn
{
	UPROPERTY(DefaultComponent, RootComponent)
	UCameraComponent CameraComp;

	UPROPERTY(DefaultComponent, Attach = CameraComp)
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

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		// Position camera on side
		SetActorLocation(SideOffset);
		SetActorRotation(FRotator(0, 90, 0)); // face the court

		// Assign to player controller
		APlayerController PC = Gameplay::GetPlayerController(0);
		if (PC != nullptr)
			PC.SetViewTargetWithBlend(this, 0.0f);

		FindBall();
	}

	UFUNCTION(BlueprintOverride)
	void Tick(float DeltaTime)
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

		// Smooth interpolation (exponential approach toward the target)
		float Alpha = Math::Clamp(FollowSpeed * DeltaTime, 0.0f, 1.0f);
		CurrentLookAt = CurrentLookAt + (BaseLookAt - CurrentLookAt) * Alpha;

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
