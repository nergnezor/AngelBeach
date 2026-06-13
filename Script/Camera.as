// End-zone camera: fixed behind Team A's baseline, tilts up to follow the ball
class ABeachVolleyballCamera : AActor
{
	UPROPERTY(DefaultComponent, RootComponent)
	UCameraComponent CameraComp;

	// Fixed camera position: behind Team A's end (X = -1100), centered Y, 3m up
	FVector CamPos = FVector(-1100, 0, 300);

	// What the camera looks at — smoothly tracks ball height
	FVector CurrentLookAt = FVector(0, 0, 150);

	float FollowSpeed = 4.0f;

	UPROPERTY()
	ABall Ball;

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		SetActorLocation(CamPos);

		APlayerController PC = Gameplay::GetPlayerController(0);
		if (PC != nullptr)
			PC.SetViewTargetWithBlend(this, 0.0f);

		FindBall();
	}

	UFUNCTION(BlueprintOverride)
	void Tick(float DeltaTime)
	{
		if (Ball == nullptr) FindBall();

		// Target look-at: court center XY, ball height when high
		FVector Target = FVector(0, 0, 150);
		if (Ball != nullptr && Ball.bInPlay)
			Target.Z = Math::Max(150.0f, Ball.Position.Z * 0.8f);

		// Smooth tilt toward target
		float Alpha = Math::Clamp(FollowSpeed * DeltaTime, 0.0f, 1.0f);
		CurrentLookAt = CurrentLookAt + (Target - CurrentLookAt) * Alpha;

		FVector LookDir = (CurrentLookAt - CamPos).GetSafeNormal();
		SetActorRotation(LookDir.Rotation());
	}

	private void FindBall()
	{
		TArray<AActor> Found;
		GetAllActorsOfClass(ABall, Found);
		if (Found.Num() > 0)
			Ball = Cast<ABall>(Found[0]);
	}
}
