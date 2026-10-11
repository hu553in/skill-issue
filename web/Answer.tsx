import { createElement, memo } from "react";
import type { ComponentProps, ReactNode } from "react";
import Markdown from "react-markdown";
import type { Components, ExtraProps } from "react-markdown";

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
