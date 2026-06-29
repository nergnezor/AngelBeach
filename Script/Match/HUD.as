// HUD - Canvas score display, minimap, phase text

class ABeachVolleyballHUD : AHUD
{
	UFUNCTION(BlueprintOverride)
	void DrawHUD(int SizeX, int SizeY)
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS == nullptr) return;

		float W = float(SizeX);
		float H = float(SizeY);

		DrawBackground(W, H);
		DrawScore(GS, W, H);
		DrawPhase(GS, W, H);
		DrawMinimap(GS, W, H);
	}

	private void DrawBackground(float W, float H)
	{
		// Semi-transparent top bar
		DrawRect(FLinearColor(0, 0, 0, 0.45f), 0, 0, W, 70);
	}

	private void DrawScore(ABeachVolleyballGameState GS, float W, float H)
	{
		// Team A score (left)
		FString ScoreA = "" + GS.ScoreA;
		DrawText(ScoreA, FLinearColor(0.3f, 0.8f, 1.0f, 1), W * 0.35f, 10, nullptr, 2.8f, false);

		// Separator
		DrawText(":", FLinearColor(1, 1, 1, 0.8f), W * 0.48f, 10, nullptr, 2.8f, false);

		// Team B score (right)
		FString ScoreB = "" + GS.ScoreB;
		DrawText(ScoreB, FLinearColor(1.0f, 0.5f, 0.2f, 1), W * 0.53f, 10, nullptr, 2.8f, false);

		// Sets
		FString SetsStr = GS.GetSetsString();
		DrawText(SetsStr, FLinearColor(1, 1, 1, 0.75f), W * 0.42f, 48, nullptr, 1.0f, false);

		// Team labels
		DrawText("YOU", FLinearColor(0.3f, 0.8f, 1.0f, 0.9f), W * 0.28f, 22, nullptr, 1.2f, false);
		DrawText("CPU", FLinearColor(1.0f, 0.5f, 0.2f, 0.9f), W * 0.66f, 22, nullptr, 1.2f, false);
	}

	private void DrawPhase(ABeachVolleyballGameState GS, float W, float H)
	{
		FString PhaseText = "";
		FLinearColor PhaseColor = FLinearColor(1, 1, 0, 1);

		switch (GS.GamePhase)
		{
		case EGamePhase::Phase_PreGame:
			PhaseText = "GET READY!";
			break;
		case EGamePhase::Phase_Serving:
			PhaseText = (GS.ServingTeam == ETeam::Team_A) ? "YOUR SERVE" : "CPU SERVE";
			break;
		case EGamePhase::Phase_PointScored:
			PhaseText = (GS.ServingTeam == ETeam::Team_A) ? "POINT FOR YOU!" : "POINT FOR CPU!";
			PhaseColor = (GS.ServingTeam == ETeam::Team_A)
				? FLinearColor(0.3f, 1.0f, 0.3f, 1)
				: FLinearColor(1.0f, 0.3f, 0.3f, 1);
			break;
		case EGamePhase::Phase_SetOver:
			PhaseText = (GS.SetsWonA > GS.SetsWonB) ? "YOU WIN THE SET!" : "CPU WINS THE SET!";
			break;
		case EGamePhase::Phase_MatchOver:
			PhaseText = (GS.MatchWinner == ETeam::Team_A) ? "YOU WIN THE MATCH!" : "CPU WINS THE MATCH!";
			PhaseColor = (GS.MatchWinner == ETeam::Team_A)
				? FLinearColor(0.2f, 1.0f, 0.2f, 1)
				: FLinearColor(1.0f, 0.2f, 0.2f, 1);
			break;
		default:
			break;
		}

		if (PhaseText.Len() > 0)
			DrawText(PhaseText, PhaseColor, W * 0.5f - PhaseText.Len() * 7, H * 0.15f, nullptr, 1.5f, false);

		// Controls hint at bottom
		FString Controls = "WASD/Stick: Move | Space/A: Jump | E/X: Pass | Shift/Y: Set | F/B: Spike";
		DrawText(Controls, FLinearColor(1,1,1,0.5f), W * 0.5f - 280, H - 28, nullptr, 0.85f, false);
	}

	// Minimap: top-right corner overhead view of court and ball
	private void DrawMinimap(ABeachVolleyballGameState GS, float W, float H)
	{
		float MapW = 160.0f;
		float MapH = 80.0f;
		float MapX = W - MapW - 10;
		float MapY = 80;

		// Background
		DrawRect(FLinearColor(0, 0.1f, 0.05f, 0.7f), MapX, MapY, MapW, MapH);

		// Court outline
		DrawRect(FLinearColor(1,1,1,0.4f), MapX, MapY, MapW, 1);
		DrawRect(FLinearColor(1,1,1,0.4f), MapX, MapY + MapH - 1, MapW, 1);
		DrawRect(FLinearColor(1,1,1,0.4f), MapX, MapY, 1, MapH);
		DrawRect(FLinearColor(1,1,1,0.4f), MapX + MapW - 1, MapY, 1, MapH);

		// Net center line
		DrawRect(FLinearColor(1,1,0,0.6f), MapX + MapW * 0.5f - 1, MapY, 2, MapH);

		// Ball dot
		TArray<AActor> Balls;
		GetAllActorsOfClass(Balls);
		if (Balls.Num() > 0)
		{
			ABall B = Cast<ABall>(Balls[0]);
			if (B != nullptr)
			{
				float BX = MapX + (B.Position.X + 800.0f) / 1600.0f * MapW;
				float BY = MapY + (B.Position.Y + 400.0f) / 800.0f * MapH;
				DrawRect(FLinearColor(1, 1, 1, 1), BX - 3, BY - 3, 6, 6);
			}
		}

		// Player dots
		TArray<AActor> Players;
		GetAllActorsOfClass(Players);
		for (AActor PA : Players)
		{
			AVolleyballPlayer P = Cast<AVolleyballPlayer>(PA);
			if (P == nullptr) continue;
			FVector Loc = P.GetActorLocation();
			float PX = MapX + (Loc.X + 800.0f) / 1600.0f * MapW;
			float PY = MapY + (Loc.Y + 400.0f) / 800.0f * MapH;
			FLinearColor PColor = (P.TeamSide == ETeam::Team_A)
				? FLinearColor(0.3f, 0.8f, 1.0f, 1)
				: FLinearColor(1.0f, 0.5f, 0.2f, 1);
			DrawRect(PColor, PX - 4, PY - 4, 8, 8);
		}
	}
}
