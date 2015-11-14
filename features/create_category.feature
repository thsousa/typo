Feature: Create a category
  As an author
  In order I can organize my articles into categories
  I want to create categories
  
  Background:
    Given the blog is set up
    And I am logged into the admin panel
    
  Scenario: Create new category
    Given I follow "Categories"
    When I fill in "Name" with "Saudades"
    And I fill in "Description" with "(S)He left us" 
    And I fill in "Keyword" with "Sua ausencia sera sentida"
    And I press "Save"
    Then I should see "Category was successfully saved." 