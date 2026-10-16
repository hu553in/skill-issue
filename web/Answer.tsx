import { createElement, memo } from "react";
import type { ComponentProps, ReactNode } from "react";
import Markdown from "react-markdown";
import type { Components, ExtraProps } from "react-markdown";
import {
  createElement as createHighlightedElement,
  Prism as SyntaxHighlighter,
} from "react-syntax-highlighter";
import vscDarkPlus from "react-syntax-highlighter/dist/esm/styles/prism/vsc-dark-plus";

const languagePattern = /\blanguage-(?<name>\S+)/u;
// Keep markup punctuation and CDATA readable at normal code sizes.
const codeTheme = {
  ...vscDarkPlus,
  cdata: { color: "#8a8a8a" },
  "tag.punctuation": { color: "#8a8a8a" },
};

function anchored(
  tag:
    | "p"
    | "li"
    | "blockquote"
    | "pre"
    | "h1"
    | "h2"
    | "h3"
    | "h4"
    | "h5"
    | "h6"
) {
  return function Block({
    node,
    ...props
  }: ExtraProps & { children?: ReactNode }) {
    return createElement(tag, {
      ...props,
      "data-anchor": `${tag}.${node?.position?.start.offset ?? 0}`,
    });
  };
}
const Link = ({
  children,
  node: _node,
  ...props
}: ComponentProps<"a"> & ExtraProps) => (
  <a {...props} target="_blank" rel="noreferrer noopener">
    {children}
  </a>
);
const Code = ({
  children,
  node,
  ...props
}: ComponentProps<"code"> & ExtraProps) => {
  if (
    typeof children !== "string" ||
    (!children.includes("\n") && (props.className ?? "") === "")
  ) {
    return <code {...props}>{children}</code>;
  }
  const offset = node?.position?.start.offset ?? 0;
  const language = languagePattern.exec(props.className ?? "")?.groups?.[
    "name"
  ];
  if (language !== undefined) {
    return (
      <SyntaxHighlighter
        className="syntax-highlight"
        codeTagProps={{ style: { fontSize: "inherit", tabSize: 4 } }}
        customStyle={{
          borderRadius: "inherit",
          fontSize: "inherit",
          margin: 0,
        }}
        language={language}
        PreTag="div"
        renderer={({ rows, stylesheet, useInlineStyles }) =>
          rows.map((row, index): ReactNode =>
            createHighlightedElement({
              key: index,
              node: {
                ...row,
                properties: {
                  className: [],
                  ...row.properties,
                  "data-anchor": `code.${offset}.${index}`,
                },
              },
              stylesheet,
              useInlineStyles,
            })
          )
        }
        style={codeTheme}
        wrapLines
        wrapLongLines
      >
        {children.replace(/\n$/u, "")}
      </SyntaxHighlighter>
    );
  }
  return (
    <code {...props}>
      {children.split(/(?<=\n)/u).map((line, index) => (
        <span data-anchor={`code.${offset}.${index}`} key={index}>
          {line}
        </span>
      ))}
    </code>
  );
};
const components: Components = {
  a: Link,
  blockquote: anchored("blockquote"),
  code: Code,
  h1: anchored("h1"),
  h2: anchored("h2"),
  h3: anchored("h3"),
  h4: anchored("h4"),
  h5: anchored("h5"),
  h6: anchored("h6"),
  li: anchored("li"),
  p: anchored("p"),
  pre: anchored("pre"),
};

// Parse the whole document so nested lists and reference links keep their meaning.
// Source offsets and component types remain stable while text is appended.
const AnswerContent = ({ text }: { text: string }) => (
  <Markdown components={components}>{text}</Markdown>
);
export const Answer = memo(AnswerContent);
