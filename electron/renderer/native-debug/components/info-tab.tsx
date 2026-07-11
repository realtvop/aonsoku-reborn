import type { DesktopAudioEngineDiagnostics } from "../../../main/native/audio/types";
import type { NativeDebugSnapshot } from "../../../main/native/debug/types";

interface Props {
  snapshot: NativeDebugSnapshot | null;
}

export function InfoTab({ snapshot }: Props) {
  if (!snapshot) {
    return <p className="text-muted-foreground p-4 text-xs">loading…</p>;
  }

  return (
    <div className="space-y-6 p-4">
      <Section title="ENGINE">
        <DiagnosticsBlock diagnostics={snapshot.diagnostics} />
        <Row k="Buffering" v={snapshot.isBuffering ? "yes" : "no"} />
        <Row k="Player Vol" v={`${(snapshot.volume * 100).toFixed(0)}%`} />
      </Section>

      <Section title="CONNECTION">
        {snapshot.connection ? (
          <>
            <Row k="Server" v={snapshot.connection.serverUrl} />
            <Row k="User" v={snapshot.connection.username} />
            <Row
              k="Auth"
              v={`${snapshot.connection.authType} · ${snapshot.connection.protocolVersion}`}
            />
            <Row
              k="Type"
              v={`${snapshot.connection.serverType}${snapshot.connection.hasFallbackUrl ? " +fallback" : ""}`}
            />
          </>
        ) : (
          <Row k="Status" v="no credentials" />
        )}
      </Section>

      <Section title="SYSTEM">
        <Row k="Memory" v={`${snapshot.system.rssMB} MB`} />
        <Row k="Electron" v={snapshot.system.electronVersion} />
        <Row k="Node" v={snapshot.system.nodeVersion} />
        <Row
          k="Platform"
          v={`${snapshot.system.platform} · ${snapshot.system.arch}`}
        />
      </Section>
    </div>
  );
}

function DiagnosticsBlock({
  diagnostics,
}: {
  diagnostics: DesktopAudioEngineDiagnostics | undefined;
}) {
  if (!diagnostics) {
    return <Row k="Backend" v="(no diagnostics)" />;
  }
  if (diagnostics.status === "available") {
    return (
      <>
        <Row k="Backend" v={diagnostics.backend} />
        <Row k="Status" v="available" />
        <Row k="Platform Key" v={diagnostics.platformKey} />
        {diagnostics.runtimeInfo &&
          Object.entries(diagnostics.runtimeInfo).map(([k, v]) => (
            <Row key={k} k={k} v={v} />
          ))}
      </>
    );
  }
  return (
    <>
      <Row k="Backend" v={diagnostics.backend} />
      <Row k="Status" v="unavailable" />
      {diagnostics.code && <Row k="Code" v={diagnostics.code} />}
      <Row k="Message" v={diagnostics.message} />
      {diagnostics.platformKey && (
        <Row k="Platform Key" v={diagnostics.platformKey} />
      )}
      {diagnostics.searchedPaths && diagnostics.searchedPaths.length > 0 && (
        <div className="mt-1">
          <div className="text-muted-foreground mb-1 text-xs">
            Searched paths
          </div>
          <ul className="text-muted-foreground space-y-0.5 pl-2 text-xs">
            {diagnostics.searchedPaths.map((p) => (
              <li key={p} className="break-all">
                {p}
              </li>
            ))}
          </ul>
        </div>
      )}
    </>
  );
}

function Section({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <section>
      <h2 className="text-muted-foreground mb-2 text-xs font-bold tracking-wider">
        {title}
      </h2>
      <div className="space-y-1">{children}</div>
    </section>
  );
}

function Row({ k, v }: { k: string; v: string }) {
  return (
    <div className="flex gap-3 text-xs">
      <span className="text-muted-foreground w-28 shrink-0">{k}</span>
      <span className="text-foreground flex-1 break-all">{v}</span>
    </div>
  );
}
