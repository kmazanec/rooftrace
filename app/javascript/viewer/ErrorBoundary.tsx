import React from "react";

// A render error in the deck.gl/MapLibre tree (e.g. malformed facet vertices)
// would otherwise unmount the whole island and leave a blank map area with no
// message. This boundary catches it and renders a friendly, reloadable fallback
// instead of a silent blank — never a bare empty viewer.
interface Props {
  children: React.ReactNode;
}

interface State {
  hasError: boolean;
}

export default class ErrorBoundary extends React.Component<Props, State> {
  constructor(props: Props) {
    super(props);
    this.state = { hasError: false };
  }

  static getDerivedStateFromError(): State {
    return { hasError: true };
  }

  componentDidCatch(error: unknown): void {
    console.error("[viewer] render error", error);
  }

  render(): React.ReactNode {
    if (this.state.hasError) {
      return (
        <div
          role="alert"
          data-testid="viewer-error"
          style={{
            position: "absolute",
            inset: 0,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            padding: 16,
            textAlign: "center",
            color: "#1c1c1e",
            background: "#f2f2f7",
            fontSize: 14,
          }}
        >
          Viewer unavailable — please reload the page.
        </div>
      );
    }
    return this.props.children;
  }
}
