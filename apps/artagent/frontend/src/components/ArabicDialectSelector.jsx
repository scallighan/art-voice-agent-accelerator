/**
 * ArabicDialectSelector
 * Selects an explicit Arabic locale when automatic dialect detection is insufficient.
 */

import { memo, useCallback, useId } from 'react';
import {
  FormControl,
  FormHelperText,
  InputLabel,
  MenuItem,
  Select,
} from '@mui/material';

export const ARABIC_DIALECT_OPTIONS = Object.freeze([
  { value: 'auto', label: 'Automatic' },
  { value: 'ar-AE', label: 'Arabic - UAE' },
  { value: 'ar-SA', label: 'Arabic - Saudi Arabia' },
  { value: 'ar-EG', label: 'Arabic - Egypt' },
  { value: 'ar-JO', label: 'Arabic - Jordan' },
]);

const ArabicDialectSelector = memo(function ArabicDialectSelector({
  value = 'auto',
  onChange,
  disabled = false,
}) {
  const labelId = useId();

  const handleChange = useCallback(
    (event) => {
      onChange?.(event.target.value);
    },
    [onChange],
  );

  return (
    <FormControl fullWidth size="small" disabled={disabled} sx={{ mt: 1 }}>
      <InputLabel id={labelId}>Arabic dialect</InputLabel>
      <Select
        labelId={labelId}
        value={value}
        label="Arabic dialect"
        onChange={handleChange}
      >
        {ARABIC_DIALECT_OPTIONS.map((option) => (
          <MenuItem key={option.value} value={option.value}>
            {option.label}
          </MenuItem>
        ))}
      </Select>
      <FormHelperText>
        Manual dialect selection applies to Voice Live. *See voice configuration docs for the
        complete Azure Arabic locale list.
      </FormHelperText>
    </FormControl>
  );
});

export default ArabicDialectSelector;
