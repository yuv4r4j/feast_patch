import React from "react";
import { EuiBadge } from "@elastic/eui";

interface DataClassificationBadgeProps {
  tags?: Record<string, string>;
}

const classificationColors: Record<string, string> = {
  PII: "danger",
  Confidential: "warning",
  Internal: "primary",
  Public: "success",
};

const DataClassificationBadge = ({ tags }: DataClassificationBadgeProps) => {
  const classification = tags?.["data_classification"];
  if (!classification || !classificationColors[classification]) {
    return null;
  }

  return (
    <EuiBadge color={classificationColors[classification]}>
      {classification}
    </EuiBadge>
  );
};

export default DataClassificationBadge;
