import Component from "@ember/component";
import UtilsMixin from "select-kit/mixins/utils";
import { computed } from "@ember/object";
import { makeArray } from "discourse-common/lib/helpers";

export default Component.extend(UtilsMixin, {
  classNames: ["select-kit-header"],
  classNameBindings: ["isFocused"],
  attributeBindings: [
    "role",
    "tabindex",
    "ariaLevel:aria-level",
    "selectedValue:data-value",
    "selectedNames:data-name",
    "buttonTitle:title",
  ],

  selectKit: null,

  role: "button",

  ariaLevel: 1,

  tabindex: 0,

  selectedValue: computed("value", function () {
    return this.value === this.getValue(this.selectKit.noneItem)
      ? null
      : makeArray(this.value).join(",");
  }),

  selectedNames: computed("selectedContent.[]", function () {
    return makeArray(this.selectedContent)
      .map((s) => this.getName(s))
      .join(",");
  }),

  buttonTitle: computed("value", "selectKit.noneItem", function () {
    if (
      !this.value &&
      this.selectKit.noneItem &&
      !this.selectKit.options.showFullTitle
    ) {
      return this.selectKit.noneItem.title || this.selectKit.noneItem.name;
    }
  }),

  icons: computed("selectKit.options.{icon,icons}", function () {
    const icon = makeArray(this.selectKit.options.icon);
    const icons = makeArray(this.selectKit.options.icons);
    return icon.concat(icons).filter(Boolean);
  }),

  didInsertElement() {
    this._super(...arguments);
    if (this.selectKit.options.autofocus) {
      this.set("isFocused", true);
    }
  },

  keyUp(event) {
    if (event.key === " ") {
      event.preventDefault();
    }
  },

  keyDown(event) {
    if (this.selectKit.isDisabled) {
      return;
    }

    if (!this.selectKit.onKeydown(event)) {
      return false;
    }

    const onlyShiftKey = event.shiftKey && event.key === "Shift";
    if (event.metaKey || onlyShiftKey) {
      return;
    }

    if (event.key === "Enter") {
      if (this.selectKit.isExpanded) {
        if (this.selectKit.highlighted) {
          this.selectKit.select(
            this.getValue(this.selectKit.highlighted),
            this.selectKit.highlighted
          );
          return false;
        }
      } else {
        this.selectKit.mainElement().open = false;
      }
    } else if (event.key === "ArrowUp") {
      if (this.selectKit.isExpanded) {
        this.selectKit.highlightPrevious();
      } else {
        this.selectKit.mainElement().open = true;
      }
      return false;
    } else if (event.key === "ArrowDown") {
      if (this.selectKit.isExpanded) {
        this.selectKit.highlightNext();
      } else {
        this.selectKit.mainElement().open = true;
      }
      return false;
    } else if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
      return true;
    } else if (event.key === "Space") {
      event.preventDefault(); // prevents the space to trigger a scroll page-next
      this.selectKit.mainElement().open = true;
    } else if (event.key === "Escape") {
      if (this.selectKit.isExpanded) {
        this.selectKit.mainElement().open = false;
      } else {
        this.element.blur();
      }
    } else if (event.key === "Backspace") {
      this._focusFilterInput();
    } else {
      return true;
    }
  },

  _focusFilterInput() {
    const filterContainer = document.querySelector(
      `#${this.selectKit.uniqueID}-filter`
    );

    if (filterContainer) {
      filterContainer.style.display = "flex";

      const filterInput = filterContainer.querySelector(".filter-input");
      filterInput && filterInput.focus();
    }
  },
});
