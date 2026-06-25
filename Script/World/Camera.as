// End-zone camera: fixed behind Team A's baseline, tilts up to follow the ball
class ABeachVolleyballCamera : AActor
{
	UPROPERTY(DefaultComponent, RootComponent)
	UCameraComponent CameraComp;

	// Fixed camera: behind Team A's baseline, lower so it looks more along the court
	// (less empty sky), angled gently down.
	FVector CamPos = FVector(-1050, 0, 420);

	// Look at the court centre, low.
	FVector CurrentLookAt = FVector(0, 0, 80);

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

		// Look at court centre; follow the ball's height only gently and clamp it so
		// the camera never tilts up into empty sky on high balls.
		FVector Target = FVector(0, 0, 120);
		if (Ball != nullptr && Ball.bInPlay)
			Target.Z = Math::Clamp(120.0f + Ball.Position.Z * 0.25f, 120.0f, 300.0f);

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
