import { type MouseEvent } from "react";
import { useTranslation } from "react-i18next";
import { useNavigate } from "react-router-dom";
import { ConfirmationDialog } from "@/app/components/ui/confirmation-dialog";
import { ROUTES } from "@/routes/routesList";
import { useAppActions, useAppStore } from "@/store/app.store";
import { usePlayerActions } from "@/store/player.store";

interface AlertDialogProps {
  openDialog: boolean;
  setOpenDialog: (value: boolean) => void;
}

export function LogoutConfirmDialog({
  openDialog,
  setOpenDialog,
}: AlertDialogProps) {
  const { removeConfig } = useAppActions();
  const setLogoutDialogState = useAppStore(
    (state) => state.actions.setLogoutDialogState,
  );
  const navigate = useNavigate();
  const { clearPlayerState, resetConfig } = usePlayerActions();
  const { t } = useTranslation();

  async function handleRemoveConfig(e: MouseEvent<HTMLButtonElement>) {
    e.preventDefault();
    await removeConfig();
    clearPlayerState();
    resetConfig();
    setLogoutDialogState(false);
    navigate(ROUTES.SERVER_CONFIG, { replace: true });
  }

  return (
    <ConfirmationDialog
      open={openDialog}
      onOpenChange={setOpenDialog}
      title={t("logout.dialog.title")}
      description={t("logout.dialog.description")}
      onConfirm={handleRemoveConfig}
    />
  );
}
