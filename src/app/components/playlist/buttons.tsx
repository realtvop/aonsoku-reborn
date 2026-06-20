import { useTranslation } from "react-i18next";
import { Actions } from "@/app/components/actions";
import { usePlayerActions } from "@/store/player.store";
import { PlaylistWithEntries } from "@/types/responses/playlist";
import { PlaylistOptions } from "./options";

interface PlaylistButtonsProps {
  playlist: PlaylistWithEntries;
}

export function PlaylistButtons({ playlist }: PlaylistButtonsProps) {
  const { t } = useTranslation();
  const { setSongList } = usePlayerActions();

  const buttonsTooltips = {
    play: t("playlist.buttons.play", { name: playlist.name }),
    shuffle: t("playlist.buttons.shuffle", { name: playlist.name }),
    options: t("playlist.buttons.options", { name: playlist.name }),
  };

  return (
    <Actions.Container>
      <Actions.Button
        tooltip={buttonsTooltips.shuffle}
        onClick={() =>
          setSongList(
            playlist.entry,
            undefined,
            true,
            { playlistId: playlist.id },
            playlist.name,
          )
        }
        disabled={!playlist.entry}
      >
        <Actions.ShuffleIcon />
      </Actions.Button>

      <Actions.Button
        tooltip={buttonsTooltips.play}
        buttonStyle="primary"
        className="md:order-first"
        onClick={() =>
          setSongList(
            playlist.entry,
            0,
            false,
            { playlistId: playlist.id },
            playlist.name,
          )
        }
        disabled={!playlist.entry}
      >
        <Actions.PlayIcon />
      </Actions.Button>

      <Actions.Dropdown
        tooltip={buttonsTooltips.options}
        options={
          <PlaylistOptions
            playlist={playlist}
            disablePlayNext={!playlist.entry}
            disableAddLast={!playlist.entry}
          />
        }
      />
    </Actions.Container>
  );
}
