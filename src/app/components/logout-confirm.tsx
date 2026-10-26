import { type MouseEvent } from "react";
import { useTranslation } from "react-i18next";
import { ConfirmationDialog } from "@/app/components/ui/confirmation-dialog";
import { restartAccountSession } from "@/lib/account-reset";
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
  const { clearPlayerState, resetConfig } = usePlayerActions();
  const { t } = useTranslation();

  async function handleRemoveConfig(e: MouseEvent<HTMLButtonElement>) {
    e.preventDefault();
    await removeConfig();
    clearPlayerState();
    resetConfig();
    setLogoutDialogState(false);
    await restartAccountSession(ROUTES.SERVER_CONFIG);
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
