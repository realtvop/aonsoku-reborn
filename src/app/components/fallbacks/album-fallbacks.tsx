import { ImageHeaderEffect } from "@/app/components/album/header-effect";
import { TableFallback } from "@/app/components/fallbacks/table-fallbacks";
import { ShadowHeaderFallback } from "@/app/components/fallbacks/ui-fallbacks";
import ListWrapper from "@/app/components/list-wrapper";
import { MainGrid } from "@/app/components/main-grid";
import { Skeleton } from "@/app/components/ui/skeleton";

export function AlbumHeaderFallback() {
  return (
    <div className="w-full px-3 py-3 sm:px-4 sm:py-4 md:px-8 md:py-6 bg-muted-foreground flex flex-col gap-2 sm:gap-3 md:gap-4 bg-gradient-to-b from-background/20 to-background/50">
      <div className="flex flex-row sm:flex-nowrap items-end sm:items-center w-full gap-3 sm:gap-4 md:gap-6 lg:gap-8">
        <Skeleton className="rounded shadow-header-image w-[120px] h-[120px] min-w-[120px] min-h-[120px] sm:w-[160px] sm:h-[160px] sm:min-w-[160px] sm:min-h-[160px] md:w-[200px] md:h-[200px] md:min-w-[200px] md:min-h-[200px] 2xl:w-[250px] 2xl:h-[250px] 2xl:min-w-[250px] 2xl:min-h-[250px] aspect-square" />
        <div className="flex w-full max-w-[calc(100%-128px)] sm:max-w-[calc(100%-172px)] md:max-w-[calc(100%-216px)] 2xl:max-w-[calc(100%-266px)] flex-col justify-end">
          <Skeleton className="h-3 sm:h-4 2xl:h-5 w-16 mb-2" />
          <Skeleton className="h-6 sm:h-12 w-[200px] sm:w-[260px] mb-2" />

          <div className="hidden sm:flex gap-2 mt-1 sm:mt-2">
            <Skeleton className="h-[22px] w-12 rounded-full" />
            <Skeleton className="h-[22px] w-12 rounded-full" />
            <Skeleton className="h-[22px] w-12 rounded-full" />
          </div>
        </div>
      </div>

      <div className="sm:hidden flex gap-2">
        <Skeleton className="h-[22px] w-12 rounded-full" />
        <Skeleton className="h-[22px] w-12 rounded-full" />
        <Skeleton className="h-[22px] w-12 rounded-full" />
      </div>
    </div>
  );
}

export function PlayButtonsFallback() {
  return (
    <div className="my-6 flex gap-1 items-center">
      <Skeleton className="rounded-full w-14 h-14 mr-2" />
      <div className="flex items-center justify-center w-14 h-14">
        <Skeleton className="rounded-full w-7 h-7" />
      </div>
      <div className="flex items-center justify-center w-14 h-14">
        <Skeleton className="rounded-full w-7 h-7" />
      </div>
    </div>
  );
}

export function AlbumFallback() {
  return (
    <div className="w-full">
      <div className="relative">
        <AlbumHeaderFallback />
        <ImageHeaderEffect className="bg-muted-foreground" />
      </div>
      <ListWrapper>
        <PlayButtonsFallback />
        <TableFallback variant="modern" />
      </ListWrapper>
    </div>
  );
}

export function AlbumsFallback() {
  return (
    <div className="w-full">
      <ShadowHeaderFallback />

      <ListWrapper className="mt-6 flex flex-col gap-4">
        <GridFallback />
      </ListWrapper>
    </div>
  );
}

function GridFallback() {
  return (
    <MainGrid>
      {Array.from({ length: 40 }).map((_, index) => (
        <div key={"card-fallback-" + index}>
          <Skeleton className="aspect-square" />
          <Skeleton className="h-[13px] w-11/12 mt-2" />
          <Skeleton className="h-3 w-1/2 mt-[7px]" />
        </div>
      ))}
    </MainGrid>
  );
}
