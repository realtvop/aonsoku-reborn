import { Heart } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Actions } from "@/app/components/actions";
import { usePlayerActions } from "@/store/player.store";
import { ISong } from "@/types/responses/song";

interface FavoritesButtonsProps {
  songs: ISong[];
  sourceName: string;
}

export function FavoritesButtons({ songs, sourceName }: FavoritesButtonsProps) {
  const { t } = useTranslation();
  const { setSongList } = usePlayerActions();

  const buttonsTooltips = {
    play: t("favorites.buttons.play", { name: sourceName }),
    shuffle: t("favorites.buttons.shuffle", { name: sourceName }),
  };

  return (
    <Actions.Container>
      <Actions.Button
        tooltip={buttonsTooltips.shuffle}
        onClick={() =>
          setSongList(songs, undefined, true, undefined, sourceName)
        }
        disabled={!songs.length}
      >
        <Actions.ShuffleIcon />
      </Actions.Button>

      <Actions.Button
        tooltip={buttonsTooltips.play}
        buttonStyle="primary"
        className="md:order-first"
        onClick={() => setSongList(songs, 0, false, undefined, sourceName)}
        disabled={!songs.length}
      >
        <Actions.PlayIcon />
      </Actions.Button>
    </Actions.Container>
  );
}

export function FavoritesIcon() {
  return <Heart className="w-24 h-24 2xl:w-32 2xl:h-32" strokeWidth={1.5} />;
}
